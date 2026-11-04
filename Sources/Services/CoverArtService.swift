import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downloads a selected release's front cover or the artwork returned by ShazamKit.
actor CoverArtService {
    private let session: URLSession
    private static let maximumBytes = 8 * 1024 * 1024

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    /// A missing cover is an ordinary result; it must never select a different release.
    func frontCover(releaseID: String) async throws -> AudioArtwork? {
        try Task.checkCancellation()
        guard let id = UUID(uuidString: releaseID) else {
            throw MusTagError.message(L10n.text("The selected release has an invalid identifier.", "所选发行版本的标识无效。"))
        }
        // CAA can have an original even when its 1200px thumbnail has not been generated.
        // Both endpoints belong to this exact release; never fall back to a release group.
        let base = "https://coverartarchive.org/release/\(id.uuidString.lowercased())"
        for endpoint in ["front-1200", "front"] {
            try Task.checkCancellation()
            if let artwork = try await download(URL(string: "\(base)/\(endpoint)")!) { return artwork }
        }
        return nil
    }

    /// Use the URL returned by ShazamKit unchanged; never substitute another recording's artwork.
    func shazamCover(url: URL) async throws -> AudioArtwork? {
        try Task.checkCancellation()
        return try await download(url, provider: .shazam)
    }

    private func download(_ url: URL, provider: CoverArtProvider = .coverArtArchive) async throws -> AudioArtwork? {
        guard CoverArtRedirectDelegate.allows(url, provider: provider) else {
            throw Self.invalidResponse(provider: provider)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")
        request.setValue("MusTag/0.1.0", forHTTPHeaderField: "User-Agent")
        let redirectDelegate = CoverArtRedirectDelegate(initialURL: url, provider: provider)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
            // Also cancel on 404, rejected headers, oversized bodies, and task cancellation.
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  CoverArtRedirectDelegate.allows(http.url, provider: provider) else {
                throw Self.invalidResponse(provider: provider)
            }
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else {
                throw MusTagError.message(L10n.text(
                    "\(provider.name) could not provide this cover (HTTP \(http.statusCode)). Try again later.",
                    "\(provider.name) 暂时无法提供此封面（HTTP \(http.statusCode)），请稍后重试。"))
            }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw Self.tooLarge() }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                // Content-Length may be missing or incorrect, so enforce the actual received size.
                guard data.count < Self.maximumBytes else { throw Self.tooLarge() }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return try Self.artwork(from: data, provider: provider)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw Self.downloadError(error, fallbackHost: redirectDelegate.lastAllowedHost, provider: provider)
        } catch let error as MusTagError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MusTagError.message(L10n.text(
                "Unable to download the cover from \(provider.name). Check your connection and retry.",
                "无法从 \(provider.name) 下载封面，请检查网络后重试。"))
        }
    }

    /// Keep only an allowlisted hostname and a numeric code; URL paths and error descriptions
    /// can contain request details and must never be echoed into the user-visible message.
    static func downloadError(_ error: URLError, fallbackHost: String,
                              provider: CoverArtProvider = .coverArtArchive) -> MusTagError {
        let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let host = CoverArtRedirectDelegate.safeHost(failingURL, provider: provider)
            ?? CoverArtRedirectDelegate.safeHost(URL(string: "https://\(fallbackHost)"), provider: provider)
            ?? provider.fallbackHost
        let reason: String
        switch error.code {
        case .timedOut:
            reason = L10n.text("The cover download timed out. Try another network or retry later.",
                               "封面下载超时，请切换网络或稍后重试。")
        case .cannotFindHost, .dnsLookupFailed:
            reason = L10n.text("The cover server's address could not be resolved. Try another network and retry.",
                               "无法解析封面服务器地址，请切换网络后重试。")
        case .cannotConnectToHost:
            reason = L10n.text("Could not connect to the cover server. Try another network or retry later.",
                               "无法连接封面服务器，请切换网络或稍后重试。")
        case .networkConnectionLost:
            reason = L10n.text("The connection was interrupted while downloading the cover. Try another network and retry.",
                               "下载封面时连接中断，请切换网络后重试。")
        case .notConnectedToInternet:
            reason = L10n.text("No internet connection is available for MusTag. Check Wi-Fi and cellular access, or try another network.",
                               "MusTag 当前无法使用网络，请检查 Wi-Fi 和蜂窝数据权限，或切换网络后重试。")
        case .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            reason = L10n.text("Mobile data is unavailable for MusTag. Check cellular data settings or connect to Wi-Fi and retry.",
                               "MusTag 当前无法使用移动数据，请检查蜂窝数据设置，或连接 Wi-Fi 后重试。")
        case .secureConnectionFailed:
            reason = L10n.text("A secure connection to the cover server could not be established. Try another network or retry later.",
                               "无法与封面服务器建立安全连接，请切换网络或稍后重试。")
        case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            reason = L10n.text("The cover connection's security certificate could not be verified. Check the device date and network, then retry.",
                               "封面连接的安全证书未通过验证，请检查设备日期及网络后重试。")
        case .appTransportSecurityRequiresSecureConnection:
            reason = L10n.text("iOS blocked the cover connection because it did not meet secure connection requirements. Try another network or retry later.",
                               "封面连接未满足安全连接要求，已被 iOS 拦截。请切换网络或稍后重试。")
        default:
            reason = L10n.text("The cover download failed. Try another network or retry later.",
                               "封面下载失败，请切换网络或稍后重试。")
        }
        return .message("\(reason) (\(host) · NSURLErrorDomain \(error.code.rawValue))")
    }

    private static func artwork(from data: Data, provider: CoverArtProvider) throws -> AudioArtwork {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.jpeg.identifier || type == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 16_384, height.doubleValue <= 16_384,
              width.doubleValue * height.doubleValue <= 40_000_000 else {
            throw invalidResponse(provider: provider)
        }
        // Force decoding before accepting a successful HTTP response as usable artwork.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
            throw invalidResponse(provider: provider)
        }
        return AudioArtwork(data: data, mimeType: type == UTType.jpeg.identifier ? "image/jpeg" : "image/png")
    }

    private static func invalidResponse(provider: CoverArtProvider) -> MusTagError {
        .message(L10n.text("\(provider.name) returned an invalid or unsupported cover image or URL.",
                           "\(provider.name) 返回的封面图片或链接无效或不受支持。"))
    }

    private static func tooLarge() -> MusTagError {
        .message(L10n.text("The cover exceeds the 8 MB download limit.", "封面超过 8 MB 下载限制。"))
    }
}

enum CoverArtProvider: Sendable {
    case coverArtArchive, shazam

    var name: String { self == .coverArtArchive ? "Cover Art Archive" : "Shazam" }
    var fallbackHost: String { self == .coverArtArchive ? "coverartarchive.org" : "mzstatic.com" }
}

/// Keep CAA/Internet Archive and Apple artwork redirects in separate trust domains.
final class CoverArtRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let provider: CoverArtProvider
    private var recordedHost: String

    init(initialURL: URL, provider: CoverArtProvider = .coverArtArchive) {
        self.provider = provider
        recordedHost = Self.safeHost(initialURL, provider: provider) ?? provider.fallbackHost
        super.init()
    }

    var lastAllowedHost: String {
        lock.lock()
        defer { lock.unlock() }
        return recordedHost
    }

    static func safeHost(_ url: URL?, provider: CoverArtProvider = .coverArtArchive) -> String? {
        guard allows(url, provider: provider) else { return nil }
        return url?.host?.lowercased()
    }

    static func allows(_ url: URL?, provider: CoverArtProvider = .coverArtArchive) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        switch provider {
        case .coverArtArchive:
            return host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org")
        case .shazam:
            return host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(allowedRedirect(request))
    }

    func allowedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let host = Self.safeHost(request.url, provider: provider) else { return nil }
        lock.lock()
        recordedHost = host
        lock.unlock()
        return request
    }
}
