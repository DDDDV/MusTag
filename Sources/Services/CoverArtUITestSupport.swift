#if DEBUG
import UIKit

/// Fixed responses are enabled only by the isolated UI-test launch arguments.
enum CoverArtUITestSupport {
    static let releaseID = "20000000-0000-0000-0000-000000000001"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverArtUITestProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func candidate(tags: AudioTags) -> MetadataCandidate {
        MetadataCandidate(id: "ui-cover-release", recordingID: "10000000-0000-0000-0000-000000000001",
                          releaseID: releaseID, tags: tags, detail: "Cover preview test edition")
    }
}

private final class CoverArtUITestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.host == "musicbrainz.org", url.path == "/ws/2/release/\(CoverArtUITestSupport.releaseID)" {
            data = Data("{\"id\":\"\(CoverArtUITestSupport.releaseID)\",\"title\":\"Test album\",\"media\":[]}".utf8)
        } else if url.host == "coverartarchive.org", url.path == "/release/\(CoverArtUITestSupport.releaseID)/front-1200" {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).pngData { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
                UIColor.systemTeal.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 60, y: 60, width: 180, height: 180))
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
