import UIKit
import XCTest
@testable import MusTag

final class CoverArtServiceTests: XCTestCase {
    private let releaseID = "20000000-0000-0000-0000-000000000001"

    override func tearDown() {
        CoverArtURLProtocol.handler = nil
        super.tearDown()
    }

    func testDownloadsOnlySelectedEditionAndDetectsActualImageType() async throws {
        let image = try imageData()
        CoverArtURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://coverartarchive.org/release/20000000-0000-0000-0000-000000000001/front-1200")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            // Some archive hosts use a generic content type; image bytes remain authoritative.
            return .init(status: 200, headers: ["Content-Type": "application/octet-stream"], data: image)
        }
        let artwork = try await service().frontCover(releaseID: releaseID)
        XCTAssertEqual(artwork?.data, image)
        XCTAssertEqual(artwork?.mimeType, "image/png")
    }

    func testJPEGIsAccepted() async throws {
        let png = try imageData()
        let jpeg = try XCTUnwrap(UIImage(data: png)?.jpegData(compressionQuality: 0.9))
        CoverArtURLProtocol.handler = { _ in .init(status: 200, data: jpeg) }
        let artwork = try await service().frontCover(releaseID: releaseID)
        XCTAssertEqual(artwork?.mimeType, "image/jpeg")
        XCTAssertEqual(artwork?.data, jpeg)
    }

    func testMissingThumbnailFallsBackToOriginalOfSameEdition() async throws {
        let image = try imageData()
        var paths: [String] = []
        CoverArtURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            paths.append(path)
            return .init(status: path.hasSuffix("front-1200") ? 404 : 200, data: image)
        }
        let artwork = try await service().frontCover(releaseID: releaseID)
        XCTAssertEqual(artwork?.data, image)
        XCTAssertEqual(paths, ["/release/\(releaseID)/front-1200", "/release/\(releaseID)/front"])
    }

    func testMissingCoverDoesNotRequestAnotherEdition() async throws {
        var paths: [String] = []
        CoverArtURLProtocol.handler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            return .init(status: 404, data: Data())
        }
        let artwork = try await service().frontCover(releaseID: releaseID)
        XCTAssertNil(artwork)
        XCTAssertEqual(paths, ["/release/\(releaseID)/front-1200", "/release/\(releaseID)/front"])
    }

    func testServiceErrorDoesNotMasqueradeAsMissingCover() async {
        CoverArtURLProtocol.handler = { _ in .init(status: 503, data: Data("unavailable".utf8)) }
        do {
            _ = try await service().frontCover(releaseID: releaseID)
            XCTFail("HTTP errors must be visible")
        } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
    }

    func testHTMLWithImageContentTypeIsRejected() async {
        CoverArtURLProtocol.handler = { _ in
            .init(status: 200, headers: ["Content-Type": "image/png"], data: Data("<html>error</html>".utf8))
        }
        await assertDownloadFails()
    }

    func testTruncatedImageIsRejected() async throws {
        let truncated = try imageData().prefix(32)
        CoverArtURLProtocol.handler = { _ in .init(status: 200, data: Data(truncated)) }
        await assertDownloadFails()
    }

    func testOversizedContentLengthIsRejected() async {
        CoverArtURLProtocol.handler = { _ in
            .init(status: 200, headers: ["Content-Length": "9000000"], data: Data())
        }
        await assertDownloadFails(expectedText: "8 MB")
    }

    func testActualBodySizeIsLimitedWithoutContentLength() async {
        CoverArtURLProtocol.handler = { _ in
            .init(status: 200, data: Data(repeating: 0, count: 8 * 1024 * 1024 + 1))
        }
        await assertDownloadFails(expectedText: "8 MB")
    }

    func testInvalidReleaseIDNeverStartsNetworkRequest() async {
        CoverArtURLProtocol.handler = { _ in
            XCTFail("Invalid identifiers must fail before networking")
            return .init(status: 200, data: Data())
        }
        do {
            _ = try await service().frontCover(releaseID: "../different-release")
            XCTFail("Expected invalid identifier error")
        } catch { XCTAssertTrue(error is MusTagError) }
    }

    func testCancellationStopsAnInFlightDownload() async {
        let started = expectation(description: "Request started")
        CoverArtURLProtocol.handler = { _ in
            started.fulfill()
            return .init(status: 200, data: Data(), stalls: true)
        }
        let service = service()
        let id = releaseID
        let download = Task { try await service.frontCover(releaseID: id) }
        await fulfillment(of: [started], timeout: 3)
        download.cancel()
        do {
            _ = try await download.value
            XCTFail("Cancelled downloads must not supply artwork")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRedirectsAllowArchiveCDNsButRejectInsecureOrUnrelatedURLs() {
        for value in ["https://coverartarchive.org/release/id/front-1200",
                      "https://archive.org/download/image.jpg",
                      "https://ia801234.us.archive.org/image.jpg"] {
            XCTAssertTrue(CoverArtRedirectDelegate.allows(URL(string: value)), value)
        }
        for value in ["http://archive.org/image.jpg", "file:///tmp/image.jpg",
                      "https://archive.org.evil.example/image.jpg", "https://evil.example/image.jpg",
                      "https://user:password@archive.org/image.jpg", "https://archive.org:444/image.jpg"] {
            XCTAssertFalse(CoverArtRedirectDelegate.allows(URL(string: value)), value)
        }
    }

    func testNetworkFailureShowsEntryHostAndCode() async {
        CoverArtURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await service().frontCover(releaseID: releaseID)
            XCTFail("Expected a transport failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(L10n.text("timed out", "超时")))
            XCTAssertTrue(error.localizedDescription.contains("coverartarchive.org"))
            XCTAssertTrue(error.localizedDescription.contains("NSURLErrorDomain -1001"))
        }
    }

    func testNetworkFailureIdentifiesArchiveImageHostWithoutExposingURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://ia801234.us.archive.org/private-path/image.jpg?token=secret-token"))
        CoverArtURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost, userInfo: [
                NSURLErrorFailingURLErrorKey: url,
                NSLocalizedDescriptionKey: "private-description secret-token"
            ])
        }
        do {
            _ = try await service().frontCover(releaseID: releaseID)
            XCTFail("Expected a transport failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ia801234.us.archive.org"))
            XCTAssertTrue(message.contains("NSURLErrorDomain -1004"))
            XCTAssertFalse(message.contains("private-path"))
            XCTAssertFalse(message.contains("secret-token"))
            XCTAssertFalse(message.contains("private-description"))
        }
    }

    func testTransportErrorCategoriesHaveActionableReasonsAndNumericCodes() {
        let cases: [(URLError.Code, String)] = [
            (.timedOut, L10n.text("timed out", "超时")),
            (.cannotFindHost, L10n.text("resolved", "解析")),
            (.dnsLookupFailed, L10n.text("resolved", "解析")),
            (.cannotConnectToHost, L10n.text("connect to", "无法连接")),
            (.networkConnectionLost, L10n.text("interrupted", "中断")),
            (.notConnectedToInternet, L10n.text("No internet", "无法使用网络")),
            (.dataNotAllowed, L10n.text("Mobile data", "移动数据")),
            (.secureConnectionFailed, L10n.text("secure connection", "安全连接")),
            (.serverCertificateUntrusted, L10n.text("certificate", "证书")),
            (.serverCertificateHasBadDate, L10n.text("certificate", "证书")),
            (.serverCertificateHasUnknownRoot, L10n.text("certificate", "证书")),
            (.serverCertificateNotYetValid, L10n.text("certificate", "证书")),
            (.clientCertificateRejected, L10n.text("certificate", "证书")),
            (.clientCertificateRequired, L10n.text("certificate", "证书")),
            (.appTransportSecurityRequiresSecureConnection, L10n.text("iOS blocked", "iOS 拦截")),
            (.unknown, L10n.text("failed", "失败"))
        ]
        for (code, reason) in cases {
            let message = CoverArtService.downloadError(URLError(code), fallbackHost: "archive.org").localizedDescription
            XCTAssertTrue(message.contains(reason), message)
            XCTAssertTrue(message.contains("archive.org"), message)
            XCTAssertTrue(message.contains("NSURLErrorDomain \(code.rawValue)"), message)
            XCTAssertFalse(message.contains("VPN"), message)
        }
    }

    func testUntrustedErrorURLsAndDescriptionsAreNeverEchoed() throws {
        for address in ["https://private-token.evil.example/private-path?token=secret",
                        "https://private-user:private-password@archive.org/private-path?token=secret",
                        "file:///private-token/private-path"] {
            let error = URLError(.unknown, userInfo: [
                NSURLErrorFailingURLErrorKey: try XCTUnwrap(URL(string: address)),
                NSLocalizedDescriptionKey: "private-description secret-token"
            ])
            let message = CoverArtService.downloadError(error, fallbackHost: "archive.org").localizedDescription
            XCTAssertTrue(message.contains("archive.org"))
            XCTAssertFalse(message.contains("private-"), message)
            XCTAssertFalse(message.contains("secret"), message)
            XCTAssertFalse(message.contains("evil.example"), message)
            XCTAssertFalse(message.contains("https://"), message)
        }
        let unknownHost = CoverArtService.downloadError(URLError(.unknown), fallbackHost: "private-token.evil.example")
        XCTAssertTrue(unknownHost.localizedDescription.contains("coverartarchive.org"))
        XCTAssertFalse(unknownHost.localizedDescription.contains("private-token"))
    }

    func testLastAllowedRedirectIdentifiesImageHostWhenErrorOmitsURL() throws {
        let initial = try XCTUnwrap(URL(string: "https://coverartarchive.org/release/id/front-1200"))
        let delegate = CoverArtRedirectDelegate(initialURL: initial)
        XCTAssertEqual(delegate.lastAllowedHost, "coverartarchive.org")
        let target = try XCTUnwrap(URL(string: "https://ia801234.us.archive.org/private-path?token=secret"))
        XCTAssertNotNil(delegate.allowedRedirect(URLRequest(url: target)))
        XCTAssertEqual(delegate.lastAllowedHost, "ia801234.us.archive.org")
        let rejected = try XCTUnwrap(URL(string: "https://private-token.evil.example/image"))
        XCTAssertNil(delegate.allowedRedirect(URLRequest(url: rejected)))
        XCTAssertEqual(delegate.lastAllowedHost, "ia801234.us.archive.org")
        let fallback = CoverArtService.downloadError(URLError(.networkConnectionLost),
                                                    fallbackHost: delegate.lastAllowedHost).localizedDescription
        XCTAssertTrue(fallback.contains("ia801234.us.archive.org"))
        XCTAssertFalse(fallback.contains("private-path"))
        XCTAssertFalse(fallback.contains("secret"))
        let errorWithURL = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: initial])
        let preferred = CoverArtService.downloadError(errorWithURL, fallbackHost: delegate.lastAllowedHost).localizedDescription
        XCTAssertTrue(preferred.contains("coverartarchive.org"))
        XCTAssertFalse(preferred.contains("ia801234.us.archive.org"))
    }

    private func assertDownloadFails(expectedText: String? = nil) async {
        do {
            _ = try await service().frontCover(releaseID: releaseID)
            XCTFail("Expected download validation to fail")
        } catch {
            XCTAssertTrue(error is MusTagError)
            if let expectedText { XCTAssertTrue(error.localizedDescription.contains(expectedText)) }
        }
    }

    private func service() -> CoverArtService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverArtURLProtocol.self]
        return CoverArtService(session: URLSession(configuration: configuration))
    }

    private func imageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
    }
}

private final class CoverArtURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var data: Data
        var stalls = false
    }
    static var handler: ((URLRequest) throws -> Response)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try XCTUnwrap(Self.handler)(request)
            if result.stalls { return }
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: result.status,
                                                       httpVersion: "HTTP/1.1", headerFields: result.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
