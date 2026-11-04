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

    func testAutomaticMatchAcceptsExactNinetyPercentWithoutRoundingUpLowerScores() {
        let boundary = candidate("boundary", score: 0.9)
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: [boundary], originalAlbum: "") else {
            return XCTFail("Exactly 90% must be eligible")
        }
        XCTAssertEqual(selected.id, boundary.id)

        let below = candidate("below", score: 0.899999)
        guard case .belowThreshold = MusicRecognitionService.automaticMatch(from: [below], originalAlbum: "") else {
            return XCTFail("A value below 90% must not become eligible through display rounding")
        }
    }

    func testAutomaticMatchChoosesHighestScoreRegardlessOfInputOrderOrOriginalAlbum() {
        let candidates = [candidate("existing-album", score: 0.94, album: "Existing Album"),
                          candidate("highest", score: 0.99, album: "Different Album"),
                          candidate("low", score: 0.5)]
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "Existing Album") else {
            return XCTFail("A unique highest score must win")
        }
        XCTAssertEqual(selected.id, "highest")
    }

    func testAutomaticMatchUsesNormalizedOriginalAlbumOnlyWithinHighestScoreTie() {
        let candidates = [candidate("other", score: 0.95, album: "Other Album"),
                          candidate("matching", score: 0.95, album: "  Original   Album  "),
                          candidate("lower", score: 0.92, album: "Original Album")]
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "\nORIGINAL\t Album\n") else {
            return XCTFail("Whitespace and case differences must not prevent an exact album match")
        }
        XCTAssertEqual(selected.id, "matching")
    }

    func testAutomaticMatchDoesNotBreakTiesWithMissingFuzzyOrNonuniqueAlbum() {
        let candidates = [candidate("deluxe", score: 0.97, album: "Album (Deluxe)"),
                          candidate("other", score: 0.97, album: "Other Album")]
        for album in ["", " \n\t", "Album", "Missing Album"] {
            guard case .ambiguous = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: album) else {
                return XCTFail("Unresolved highest-score editions must remain ambiguous: \(album)")
            }
        }
        let matchingEditions = [candidate("edition-a", score: 0.97, album: "Album"),
                                candidate("edition-b", score: 0.97, album: " ALBUM ")]
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: matchingEditions, originalAlbum: "Album") else {
            return XCTFail("The original album cannot choose between two matching editions")
        }
    }

    func testAutomaticMatchNeverChoosesLowerScoringAlbumToResolveTopTie() {
        let candidates = [candidate("top-a", score: 0.97, album: "First"),
                          candidate("top-b", score: 0.97, album: "Second"),
                          candidate("existing", score: 0.96, album: "Existing")]
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "Existing") else {
            return XCTFail("Album preference must never lower the fingerprint score")
        }
    }

    func testAutomaticMatchRequiresValidFingerprintScore() {
        let invalidScores: [Double?] = [nil, .nan, .infinity, -.infinity, -0.01, 1.01]
        let invalid = invalidScores.enumerated().map { candidate("invalid-\($0.offset)", score: $0.element) }
        for candidates in [[], invalid] {
            guard case .noMatch = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "") else {
                return XCTFail("Missing or invalid fingerprint scores cannot drive automatic matching")
            }
        }
        guard case .belowThreshold = MusicRecognitionService.automaticMatch(from: invalid + [candidate("zero", score: 0)], originalAlbum: "") else {
            return XCTFail("A valid zero score is a below-threshold match")
        }
    }

    func testCandidateRankingDeduplicatesByBestScoreAndStabilizesTies() {
        let candidates = [candidate("b", score: 0.5), candidate("z-nil", score: nil),
                          candidate("c", score: 0.9), candidate("b", score: 0.98),
                          candidate("a", score: 0.98), candidate("y-invalid", score: 1.2),
                          candidate("x-nan", score: .nan), candidate("d-zero", score: 0)]
        let ranked = MusicRecognitionService.rankedCandidates(candidates)
        XCTAssertEqual(ranked.map(\.id), ["a", "b", "c", "d-zero", "x-nan", "y-invalid", "z-nil"])
        XCTAssertEqual(ranked[1].score, 0.98)
        XCTAssertEqual(MusicRecognitionService.rankedCandidates(Array(candidates.reversed())).map(\.id), ranked.map(\.id))

        let repeated = candidate("same", score: 0.95)
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: [repeated, repeated], originalAlbum: "") else {
            return XCTFail("Repeated copies of one candidate are not an ambiguous tie")
        }
        XCTAssertEqual(selected.id, repeated.id)
    }

    func testAllReturnedReleaseEditionsParticipateInAutomaticSelection() {
        let releases = (1...13).map { index in
            MBRelease(id: "release-\(index)", title: index == 13 ? "Existing Album" : "Edition \(index)")
        }
        let recording = MBRecording(id: recordingID, title: "Song", releases: releases)
        let candidates = MusicRecognitionService.candidates(from: recording, fingerprintScore: 0.96)
        XCTAssertEqual(candidates.count, 13)
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "Existing Album") else {
            return XCTFail("An album beyond the former twelve-edition limit must remain selectable")
        }
        XCTAssertEqual(selected.releaseID, "release-13")

        var additionalEdition = releases[12]
        additionalEdition.id = "release-14"
        let ambiguousRecording = MBRecording(id: recordingID, title: "Song", releases: releases + [additionalEdition])
        let ambiguous = MusicRecognitionService.candidates(from: ambiguousRecording, fingerprintScore: 0.96)
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: ambiguous, originalAlbum: "Existing Album") else {
            return XCTFail("A later duplicate album edition must prevent a false unique match")
        }
    }

    func testRecordingMatchesUseIDToOrderEqualScores() {
        let firstID = "10000000-0000-0000-0000-000000000001"
        let secondID = "10000000-0000-0000-0000-000000000002"
        let response = AcoustIDResponse(status: "ok", results: [
            AcoustIDResult(score: 0.95, recordings: [AcoustIDRecording(id: secondID), AcoustIDRecording(id: firstID)])
        ])
        XCTAssertEqual(MusicRecognitionService.recordingMatches(from: response).map(\.id), [firstID, secondID])
    }

    func testIdentifyPreservesTiedRecordingsBeyondFiveBeforeChoosingAnAlbum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp3")
        try Data("fixture".utf8).write(to: source)
        let ids = (1...6).map { "10000000-0000-0000-0000-\(String(format: "%012d", $0))" }
        RecognitionURLProtocol.handler = { request in
            if request.url?.host == "api.acoustid.org" {
                let results = ids.reversed().map { ["id": $0, "title": "Song"] }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "status": "ok", "results": [["score": 0.95, "recordings": results]]
                ]))
            }
            let id = try XCTUnwrap(request.url?.lastPathComponent)
            let album = id == ids.first || id == ids.last ? "Existing Album" : "Other \(id)"
            return (200, try JSONSerialization.data(withJSONObject: [
                "id": id, "title": "Song", "releases": [["id": "release-\(id)", "title": album]]
            ]))
        }
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0,
            minimumAcoustIDInterval: 0, fingerprintProvider: { _ in ("fingerprint", 120) })
        let candidates = try await service.identify(url: source, apiKey: "key")
        XCTAssertEqual(candidates.map(\.recordingID), ids)
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "Existing Album") else {
            return XCTFail("The sixth tied recording must prevent the first album from appearing unique")
        }
    }

    func testIncompleteReleaseLookupCannotResolveTopTieButAllowsUniquePartialMatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp3")
        try Data("fixture".utf8).write(to: source)
        let completeID = recordingID
        let partialID = "10000000-0000-0000-0000-000000000002"
        let release = releaseID
        RecognitionURLProtocol.handler = { request in
            if request.url?.host == "api.acoustid.org" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "status": "ok", "results": [["score": 0.96, "recordings": [
                        ["id": completeID, "title": "Complete song"],
                        ["id": partialID, "title": "Partial song"]
                    ]]]
                ]))
            }
            if request.url?.lastPathComponent == partialID { return (500, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: [
                "id": completeID, "title": "Complete song",
                "releases": [["id": release, "title": "Existing Album"]]
            ]))
        }
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0,
            minimumAcoustIDInterval: 0, fingerprintProvider: { _ in ("fingerprint", 120) })
        let candidates = try await service.identify(url: source, apiKey: "key")
        XCTAssertEqual(candidates.count, 2)
        let complete = try XCTUnwrap(candidates.first { $0.recordingID == completeID })
        let partial = try XCTUnwrap(candidates.first { $0.recordingID == partialID })
        XCTAssertFalse(complete.hasIncompleteReleaseInfo)
        XCTAssertTrue(partial.hasIncompleteReleaseInfo)
        XCTAssertEqual(partial.tags.title, "Partial song")
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "Existing Album") else {
            return XCTFail("An unavailable edition list cannot prove a unique album match")
        }
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: [partial], originalAlbum: "Existing Album") else {
            return XCTFail("A unique highest recording can still supply its partial title and artist")
        }
        XCTAssertEqual(selected.id, partial.id)
    }

    func testTextSearchResultsHaveNoFingerprintScoreAndCannotAutomaticallyMatch() async throws {
        let id = recordingID
        RecognitionURLProtocol.handler = { _ in
            (200, Data("{\"recordings\":[{\"id\":\"\(id)\",\"title\":\"Song\",\"score\":100}]}".utf8))
        }
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0)
        let candidates = try await service.search(title: "Song", artist: "")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.score)
        guard case .noMatch = MusicRecognitionService.automaticMatch(from: candidates, originalAlbum: "") else {
            return XCTFail("MusicBrainz text relevance is not a fingerprint score")
        }
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

    func testHTTP400InvalidKeyExplainsApplicationKeyWithoutRetrying() async throws {
        let message = try await identificationError(status: 400, body: """
        {"error":{"code":4,"message":"invalid API key"},"status":"error"}
        """)
        XCTAssertTrue(message.contains("AcoustID"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Application API Key"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("User API Key"))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertFalse(message.contains("private-key"))
    }

    func testHTTP200AcoustIDErrorStillExplainsApplicationKey() async throws {
        let message = try await identificationError(status: 200, body: """
        {"error":{"code":4,"message":"invalid API key"},"status":"error"}
        """)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Application API Key"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("User API Key"))
    }

    func testHTTP400InvalidFingerprintIsNotReportedAsKeyFailure() async throws {
        let message = try await identificationError(status: 400, body: """
        {"error":{"code":3,"message":"invalid fingerprint"},"status":"error"}
        """)
        XCTAssertTrue(message.contains(L10n.text("fingerprint", "指纹")))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("API Key"))
    }

    func testHTTP400InvalidDurationIsNotReportedAsKeyFailure() async throws {
        let message = try await identificationError(status: 400, body: """
        {"error":{"code":8,"message":"invalid duration"},"status":"error"}
        """)
        XCTAssertTrue(message.contains(L10n.text("duration", "时长")))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("API Key"))
    }

    func testAcoustIDInternalErrorIsNeverReportedAsInvalidKey() async throws {
        for status in [200, 500] {
            let message = try await identificationError(status: status, body: """
            {"error":{"code":5,"message":"internal error"},"status":"error"}
            """)
            XCTAssertTrue(message.contains("AcoustID"))
            XCTAssertTrue(message.contains(L10n.text("internal", "内部")))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("API Key"))
        }
    }

    func testUnknownAcoustIDErrorPreservesProviderAndStatusWithoutEchoingBody() async throws {
        let message = try await identificationError(status: 400, body: """
        {"error":{"code":999,"message":"rejected private-key and test-fingerprint"},"status":"error"}
        """)
        XCTAssertTrue(message.contains("AcoustID"))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertTrue(message.contains("999"))
        XCTAssertFalse(message.contains("private-key"))
        XCTAssertFalse(message.contains("test-fingerprint"))
        XCTAssertFalse(message.contains(L10n.text("unavailable", "暂不可用")))
    }

    func testHTTP400HTMLResponseHasSafeRequestErrorFallback() async throws {
        let message = try await identificationError(status: 400,
            body: "<html><body>Bad request: client=private-key</body></html>")
        XCTAssertTrue(message.contains("AcoustID"))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertTrue(message.contains(L10n.text("request", "请求")))
        XCTAssertFalse(message.contains("<html>"))
        XCTAssertFalse(message.contains("private-key"))
        XCTAssertFalse(message.contains("DecodingError"))
        XCTAssertFalse(message.contains(L10n.text("unavailable", "暂不可用")))
    }

    private func candidate(_ id: String, score: Double?, album: String = "") -> MetadataCandidate {
        MetadataCandidate(id: id, recordingID: recordingID, releaseID: id,
                          tags: AudioTags(title: "Song", album: album), score: score, detail: "")
    }

    private func identificationError(status: Int, body: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp3")
        try Data("private audio content".utf8).write(to: source)
        RecognitionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.acoustid.org", "Failed lookups must not continue to MusicBrainz")
            XCTAssertEqual(request.url?.path, "/v2/lookup")
            return (status, Data(body.utf8))
        }
        let initialRequestCount = RecognitionURLProtocol.requestCount
        let service = MusicRecognitionService(session: session(), minimumMusicBrainzInterval: 0,
            minimumAcoustIDInterval: 0, fingerprintProvider: { _ in ("test-fingerprint", 120.6) })
        do {
            _ = try await service.identify(url: source, apiKey: "private-key")
            XCTFail("Expected AcoustID lookup to fail")
            return ""
        } catch {
            XCTAssertEqual(RecognitionURLProtocol.requestCount - initialRequestCount, 1,
                           "Invalid requests and internal errors must not be retried")
            return error.localizedDescription
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
