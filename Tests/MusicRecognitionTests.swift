import XCTest
@testable import MusTag

final class MusicRecognitionTests: XCTestCase {
    private let recordingID = "10000000-0000-0000-0000-000000000001"
    private let releaseID = "20000000-0000-0000-0000-000000000001"

    override func tearDown() {
        RecognitionURLProtocol.reset()
        super.tearDown()
    }

    func testRecordingKeepsReleaseEditionsSeparateAndPreservesArtistCredit() throws {
        let data = Data("""
        {"id":"\(recordingID)","title":"Song","length":123400,
         "artist-credit":[{"name":"A","joinphrase":" feat. "},{"artist":{"name":"B"}}],
         "releases":[
           {"id":"\(releaseID)","title":"Original","date":"1999-08-01","country":"GB"},
           {"id":"20000000-0000-0000-0000-000000000002","title":"Reissue","date":"2025","disambiguation":"remaster"}
         ]}
        """.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: data)
        let candidates = MusicRecognitionService.candidates(from: recording, fingerprintScore: 0.91)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertNotEqual(candidates[0].id, candidates[1].id)
        XCTAssertEqual(candidates[0].tags.artist, "A feat. B")
        XCTAssertEqual(candidates[0].tags.year, "1999")
        XCTAssertEqual(candidates[1].tags.year, "2025")
        XCTAssertEqual(candidates[0].duration, 123.4)
        XCTAssertEqual(candidates[0].tags.trackNumber, "")
        XCTAssertEqual(candidates[0].tags.albumArtist, "")
    }

    func testReleaseResolutionDoesNotGuessDuplicateTrackPosition() throws {
        let release = try JSONDecoder().decode(MBRelease.self, from: Data("""
        {"id":"\(releaseID)","title":"Box set","date":"2024-06-01", "media":[
         {"position":1,"tracks":[{"position":2,"recording":{"id":"\(recordingID)"}}]},
         {"position":2,"tracks":[{"position":7,"recording":{"id":"\(recordingID)"}}]}
        ]}
        """.utf8))
        let candidate = MetadataCandidate(id: "candidate", recordingID: recordingID, releaseID: releaseID,
            tags: AudioTags(title: "Song"), detail: "MusicBrainz")
        let resolved = MusicRecognitionService.resolve(candidate, with: release)
        XCTAssertEqual(resolved.tags.album, "Box set")
        XCTAssertEqual(resolved.tags.trackNumber, "")
        XCTAssertEqual(resolved.tags.discNumber, "")
        XCTAssertNotEqual(resolved.detail, candidate.detail)
    }

    func testReleaseResolutionUsesTrackCreditAndExactDiscPosition() throws {
        let release = try JSONDecoder().decode(MBRelease.self, from: Data("""
        {"id":"\(releaseID)","title":"Album","date":"2001-06-01",
         "artist-credit":[{"name":"Various Artists"}],"media":[
         {"position":2,"tracks":[{"position":7,"title":"Release title","length":200000,
           "artist-credit":[{"name":"Track Artist"}],"recording":{"id":"\(recordingID)"}}]}
        ]}
        """.utf8))
        let candidate = MetadataCandidate(id: "candidate", recordingID: recordingID, releaseID: releaseID,
            tags: AudioTags(title: "Recording title", artist: "Recording Artist"), detail: "MusicBrainz")
        let resolved = MusicRecognitionService.resolve(candidate, with: release)
        XCTAssertEqual(resolved.tags.title, "Release title")
        XCTAssertEqual(resolved.tags.artist, "Track Artist")
        XCTAssertEqual(resolved.tags.albumArtist, "Various Artists")
        XCTAssertEqual(resolved.tags.trackNumber, "7")
        XCTAssertEqual(resolved.tags.discNumber, "2")
        XCTAssertEqual(resolved.duration, 200)
    }

    func testAcoustIDMatchesDeduplicateRecordingAndRetainHighestScore() throws {
        let response = try JSONDecoder().decode(AcoustIDResponse.self, from: Data("""
        {"status":"ok","results":[
          {"score":0.4,"recordings":[{"id":"\(recordingID)","title":"Song"}]},
          {"score":0.9,"recordings":[{"id":"\(recordingID)","title":"Song"}]},
          {"score":1.0,"recordings":[{"id":"invalid-id"}]}
        ]}
        """.utf8))
        let matches = MusicRecognitionService.recordingMatches(from: response)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.9)
    }

    func testMissingKeyDoesNotTouchAudioOrNetwork() async {
        let service = MusicRecognitionService(session: session(), fingerprintProvider: { _ in
            XCTFail("Missing-key path must not fingerprint files")
            return ("", 0)
        })
        do {
            _ = try await service.identify(url: URL(fileURLWithPath: "/does-not-exist.mp3"), apiKey: "  ")
            XCTFail("Expected missing key error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("API"))
        }
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testSearchEscapesUserQueryAndCachesResults() async throws {
        RecognitionURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = components.queryItems?.first { $0.name == "query" }?.value
            XCTAssertEqual(query, #"recording:"A \"title\"" AND artist:"AC\/DC""#)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            return (200, Data("{\"recordings\":[]}".utf8))
        }
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0)
        let first = try await service.search(title: "A \"title\"", artist: "AC/DC")
        let second = try await service.search(title: "A \"title\"", artist: "AC/DC")
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 1)
    }

    func testFingerprintIsPostedWithoutAudioOrKeyInURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp3")
        try Data("private audio content".utf8).write(to: source)
        RecognitionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.acoustid.org")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.requestBody(request))
            XCTAssertTrue(body.contains("fingerprint=test-fingerprint"))
            XCTAssertTrue(body.contains("client=private-key"))
            XCTAssertTrue(body.contains("duration=121"))
            XCTAssertFalse(body.contains("private audio content"))
            return (200, Data("{\"status\":\"ok\",\"results\":[]}".utf8))
        }
        let service = MusicRecognitionService(session: session(), minimumAcoustIDInterval: 0,
            fingerprintProvider: { localURL in
                XCTAssertNotEqual(localURL, source)
                XCTAssertEqual(try Data(contentsOf: localURL), Data("private audio content".utf8))
                return ("test-fingerprint", 120.6)
            })
        let results = try await service.identify(url: source, apiKey: "private-key")
        XCTAssertTrue(results.isEmpty)
    }

    func testInvalidJSONReturnsReadableError() async {
        RecognitionURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0)
        do {
            _ = try await service.search(title: "Song", artist: "")
            XCTFail("Expected a response error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("DecodingError"))
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecognitionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBody(_ request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class RecognitionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    static func reset() {
        handler = nil
        lock.lock(); count = 0; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
