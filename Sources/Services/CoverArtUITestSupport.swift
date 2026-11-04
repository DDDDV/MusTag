#if DEBUG
import UIKit

/// Fixed responses are enabled only by the isolated UI-test launch arguments.
enum CoverArtUITestSupport {
    static let recordingID = "10000000-0000-0000-0000-000000000001"
    static let lowerRecordingID = "10000000-0000-0000-0000-000000000002"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverArtUITestProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func candidate(tags: AudioTags) -> MetadataCandidate {
        var match = shazamResult()
        match.title = tags.title
        match.artist = tags.artist
        return MetadataCandidate(id: "ui-cover-release", tags: tags, detail: "Cover preview test match",
                                 source: .shazamKit, artworkURL: match.artworkURL,
                                 appleMusicURL: match.appleMusicURL, shazamMetadata: match)
    }

    static func shazamResult() -> ShazamRecognitionResult {
        ShazamRecognitionResult(id: "ui-shazam-song", title: "Shazam matched title",
            artist: "Shazam matched artist", genres: ["Pop"], isrc: "USAAA2600001",
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/ui-shazam-cover.png"),
            appleMusicURL: URL(string: "https://music.apple.com/us/album/test/123?i=456"),
            subtitle: "Shazam supplementary details", appleMusicID: "456",
            webURL: URL(string: "https://www.shazam.com/track/456/test"), explicitContent: false)
    }

    static func appleMusicSong() -> AppleMusicSongMetadata {
        AppleMusicSongMetadata(id: "456", title: "Catalog title differs", artist: "Catalog artist differs",
            albumTitle: "Test album", albumArtist: "Album artist",
            releaseDate: ISO8601DateFormatter().date(from: "1998-04-05T00:00:00Z"),
            trackNumber: 7, discNumber: 2, isrc: "USAAA2600001", duration: 120,
            url: URL(string: "https://music.apple.com/us/album/test/123?i=456"),
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/ui-shazam-cover.png"), genres: ["Jazz"])
    }

}

private final class CoverArtUITestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.host == "api.acoustid.org", url.path == "/v2/lookup" {
            // Deliberately return the lower score first to exercise the user-visible ranking.
            data = Data("""
            {"status":"ok","results":[
              {"score":0.89,"recordings":[{"id":"\(CoverArtUITestSupport.lowerRecordingID)","title":"Similar title","duration":120,"artists":[{"name":"Other artist"}]}]},
              {"score":0.97,"recordings":[{"id":"\(CoverArtUITestSupport.recordingID)","title":"Matched title","duration":120,"artists":[{"name":"Matched artist"}]}]}
            ]}
            """.utf8)
        } else if url.host == "is1-ssl.mzstatic.com", url.path == "/ui-shazam-cover.png" {
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
