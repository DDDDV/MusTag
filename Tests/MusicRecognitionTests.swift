import XCTest
import MusicKit
@testable import MusTag

final class MusicRecognitionTests: XCTestCase {
    private let recordingID = "10000000-0000-0000-0000-000000000001"

    override func tearDown() {
        RecognitionURLProtocol.reset()
        super.tearDown()
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

    func testRecordingMatchesUseIDToOrderEqualScores() {
        let firstID = "10000000-0000-0000-0000-000000000001"
        let secondID = "10000000-0000-0000-0000-000000000002"
        let response = AcoustIDResponse(status: "ok", results: [
            AcoustIDResult(score: 0.95, recordings: [AcoustIDRecording(id: secondID), AcoustIDRecording(id: firstID)])
        ])
        XCTAssertEqual(MusicRecognitionService.recordingMatches(from: response).map(\.id), [firstID, secondID])
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

    func testShazamFailureRemovesStagedFile() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("local audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let captured = ShazamStagedFile()
        let service = MusicRecognitionService(shazamProvider: { staged in
            await captured.record(staged)
            throw CancellationError()
        })
        do {
            _ = try await service.identify(url: source, apiKey: "", provider: .shazamKit)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let staged = await captured.url
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged).deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testShazamAutomaticChoiceDoesNotUseAcoustIDThresholdOrAlbumPreference() {
        var first = candidate("shazam:first", score: nil, album: "Existing")
        first.source = .shazamKit
        var second = candidate("shazam:second", score: nil)
        second.source = .shazamKit
        guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: [first], originalAlbum: "") else {
            return XCTFail("A unique Shazam match should enter the draft without inventing a score")
        }
        XCTAssertEqual(selected.id, first.id)
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: [first, second], originalAlbum: "Existing") else {
            return XCTFail("Shazam matches must not be disambiguated using AcoustID edition rules")
        }
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: [first, candidate("other", score: 1)], originalAlbum: "") else {
            return XCTFail("Mixed provider results cannot share a confidence scale")
        }
    }

    func testGenresUseChineseNamesForEnglishProviderValues() {
        XCTAssertEqual(
            GenreLocalization.localized(["pop", "Mandopop", "MUSIC", "Rock", "Jazz", "R&B/Soul"], isChinese: true),
            "流行; 国语流行; 音乐; 摇滚; 爵士; R&B/灵魂乐")
    }

    func testGenresUseEnglishNamesForSimplifiedAndTraditionalChineseProviderValues() {
        for genres in [["国语流行", "音乐", "国际流行"], ["國語流行", "音樂", "國際流行"]] {
            XCTAssertEqual(GenreLocalization.localized(genres, isChinese: false), "Mandopop; Music; Pop")
        }
    }

    func testGenreAliasesDeduplicateWithoutChangingProviderOrder() {
        let genres = [" Jazz ", "pop", "国际流行", "流行", "POP", "Mandopop", "國語流行", "爵士"]
        XCTAssertEqual(GenreLocalization.localized(genres, isChinese: true), "爵士; 流行; 国语流行")
        XCTAssertEqual(GenreLocalization.localized(genres, isChinese: false), "Jazz; Pop; Mandopop")
    }

    func testUnknownGenresKeepTheirOriginalTextInBothLanguages() {
        let genres = ["  Future Garage  ", "地方曲风", "R&B/Soul"]
        XCTAssertEqual(GenreLocalization.localized(genres, isChinese: true), "Future Garage; 地方曲风; R&B/灵魂乐")
        XCTAssertEqual(GenreLocalization.localized(genres, isChinese: false), "Future Garage; 地方曲风; R&B/Soul")
    }

    func testGenreLocalizationOmitsEmptyValuesAndTrimsWhitespace() {
        for isChinese in [false, true] {
            XCTAssertEqual(GenreLocalization.localized([], isChinese: isChinese), "")
            XCTAssertEqual(GenreLocalization.localized(["", " \n\t "], isChinese: isChinese), "")
            XCTAssertEqual(GenreLocalization.localized(["", " \nPop\t ", "  "], isChinese: isChinese),
                           isChinese ? "流行" : "Pop")
        }
    }

    func testAcoustIDReturnsItsOwnMetadataWithoutSecondaryRequests() async throws {
        let id = recordingID
        RecognitionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.acoustid.org")
            return (200, Data("""
            {"status":"ok","results":[{"score":0.96,"recordings":[
             {"id":"\(id)","title":"Recognized title","duration":123.4,
              "artists":[{"name":"First artist"},{"name":"Second artist"}]}]}]}
            """.utf8))
        }
        let service = MusicRecognitionService(session: session(), minimumAcoustIDInterval: 0,
            fingerprintProvider: { _ in ("fingerprint", 120) }, appleMusicProvider: { _ in
                XCTFail("AcoustID must not query Apple Music")
                return nil
            })
        let source = try temporaryAudio()
        defer { try? FileManager.default.removeItem(at: source) }
        let matches = try await service.identify(url: source, apiKey: "key")
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(match.tags.title, "Recognized title")
        XCTAssertEqual(match.tags.artist, "First artist, Second artist")
        XCTAssertEqual(match.duration, 123.4)
        XCTAssertEqual(match.score, 0.96)
        XCTAssertEqual(match.source, .acoustID)
        XCTAssertTrue(match.tags.album.isEmpty)
        XCTAssertTrue(match.tags.year.isEmpty)
        XCTAssertTrue(match.tags.trackNumber.isEmpty)
        XCTAssertTrue(match.tags.discNumber.isEmpty)
        XCTAssertNil(match.artworkURL)
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 1)
    }

    func testAcoustIDPreservesAllTiedRecordingsAndDoesNotChooseByAlbum() async throws {
        let ids = (1...6).map { "10000000-0000-0000-0000-\(String(format: "%012d", $0))" }
        RecognitionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.acoustid.org")
            return (200, try JSONSerialization.data(withJSONObject: [
                "status": "ok", "results": [["score": 0.95, "recordings": ids.reversed().map {
                    ["id": $0, "title": "Song"]
                }]]
            ]))
        }
        let service = MusicRecognitionService(session: session(), minimumAcoustIDInterval: 0,
            fingerprintProvider: { _ in ("fingerprint", 120) })
        let source = try temporaryAudio()
        defer { try? FileManager.default.removeItem(at: source) }
        let matches = try await service.identify(url: source, apiKey: "key")
        XCTAssertEqual(matches.count, 6)
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: matches, originalAlbum: "Existing") else {
            return XCTFail("Tied recording identities require manual selection")
        }
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 1)
    }

    func testInvalidJSONReturnsReadableError() async throws {
        let message = try await identificationError(status: 200, body: "not json")
        XCTAssertFalse(message.contains("DecodingError"))
        XCTAssertFalse(message.contains("not json"))
    }

    func testShazamStagesLocalAudioAndDoesNotQueryWithoutCatalogID() async throws {
        let source = try temporaryAudio()
        defer { try? FileManager.default.removeItem(at: source) }
        let captured = ShazamStagedFile()
        let service = MusicRecognitionService(session: session(), fingerprintProvider: { _ in
            XCTFail("Shazam must not invoke fingerprinting for AcoustID")
            return ("", 0)
        }, shazamProvider: { staged in
            await captured.record(staged)
            XCTAssertNotEqual(staged, source)
            XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: source))
            return [.init(id: "123", title: "Song", artist: "Artist", genres: ["Pop"],
                          appleMusicURL: URL(string: "https://music.apple.com/us/song/123"))]
        }, appleMusicProvider: { _ in
            XCTFail("Without an Apple Music ID the service must keep the basic match")
            return nil
        })
        let matches = try await service.identify(url: source, apiKey: "", provider: .shazamKit)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(match.id, "shazam:123")
        XCTAssertEqual(match.source, .shazamKit)
        XCTAssertNil(match.score)
        XCTAssertEqual(match.tags.genre, L10n.text("Pop", "流行"))
        XCTAssertTrue(match.tags.album.isEmpty)
        XCTAssertNotNil(match.appleMusicURL)
        XCTAssertNotNil(match.supplementationNotice)
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
        let staged = await captured.url
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged).deletingLastPathComponent().path))
    }

    func testShazamDropsEmptyAndDuplicateMatchesAndUntrustedLinks() async throws {
        let service = MusicRecognitionService(session: session(), shazamProvider: { _ in
            let result = ShazamRecognitionResult(id: "123", title: "Song", artist: "Artist",
                appleMusicURL: URL(string: "https://music.apple.com.example.org/song/123"))
            return [result, result, .init(id: "456", title: "  ", artist: "")]
        }, appleMusicProvider: { _ in
            XCTFail("No valid catalog ID was returned")
            return nil
        })
        let matches = try await identifyShazam(using: service)
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches.first?.appleMusicURL)
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testAppleMusicCompletesEditionWithoutReplacingShazamPrimaryMetadata() async throws {
        let shazam = ShazamRecognitionResult(id: "123", title: "Shazam title", artist: "Shazam artist",
            genres: ["Pop"], isrc: "us-aaa-26-00001",
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/shazam.jpg"), appleMusicID: "456")
        let song = appleSong()
        let matches = try await identifyShazam(using: shazamService(shazam) { id in
            XCTAssertEqual(id, "456")
            return song
        })
        XCTAssertEqual(matches.count, 2)
        let edition = try XCTUnwrap(matches.first { $0.appleMusicMetadata != nil })
        XCTAssertEqual(edition.tags.title, shazam.title)
        XCTAssertEqual(edition.tags.artist, shazam.artist)
        XCTAssertEqual(edition.tags.genre, L10n.text("Pop", "流行"))
        XCTAssertEqual(edition.tags.album, "Catalog album")
        XCTAssertEqual(edition.tags.albumArtist, "Album artist")
        XCTAssertEqual(edition.tags.year, "1998")
        XCTAssertEqual(edition.tags.trackNumber, "7")
        XCTAssertEqual(edition.tags.discNumber, "2")
        XCTAssertEqual(edition.duration, 210)
        XCTAssertEqual(edition.artworkURL, song.artworkURL, "The selected catalog edition supplies its own cover")
        XCTAssertEqual(edition.appleMusicMetadata, song)
        XCTAssertEqual(edition.shazamMetadata, shazam)
        XCTAssertNil(edition.score)
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testAppleMusicAutomaticSelectionRequiresCompatibleAlbum() async throws {
        let song = appleSong()
        let matches = try await identifyShazam(using: shazamService(catalogShazam()) { _ in song })
        for album in ["", "  CATALOG\t album  "] {
            guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: matches, originalAlbum: album) else {
                return XCTFail("A compatible catalog album should supplement the unique song")
            }
            XCTAssertEqual(selected.appleMusicMetadata, song)
        }
        for album in ["Different edition", "Catalog album (Deluxe)"] {
            guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: matches, originalAlbum: album) else {
                return XCTFail("An incompatible edition must keep the basic Shazam match")
            }
            XCTAssertNil(selected.appleMusicMetadata)
            XCTAssertTrue(selected.tags.album.isEmpty)
            XCTAssertNotNil(selected.supplementationNotice)
        }
    }

    func testMissingCatalogArtworkRetainsShazamArtwork() async throws {
        let shazam = ShazamRecognitionResult(id: "123", title: "Shazam title", artist: "Shazam artist",
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/shazam.jpg"), appleMusicID: "456")
        var catalog = appleSong()
        catalog.artworkURL = nil
        let song = catalog
        let matches = try await identifyShazam(using: shazamService(shazam) { _ in song })
        XCTAssertEqual(matches.first { $0.appleMusicMetadata != nil }?.artworkURL, shazam.artworkURL)
    }

    func testAutomaticSelectionDeduplicatesAcoustIDUsingItsHighestScore() {
        let duplicates = [candidate("same", score: 0.4), candidate("same", score: 0.98),
                          candidate("other", score: 0.95)]
        for matches in [duplicates, Array(duplicates.reversed())] {
            guard case .selected(let selected) = MusicRecognitionService.automaticMatch(from: matches, originalAlbum: "") else {
                return XCTFail("Duplicate identities must retain their highest fingerprint score")
            }
            XCTAssertEqual(selected.id, "same")
            XCTAssertEqual(selected.score, 0.98)
        }
    }

    func testAppleMusicMissingFieldsAndInvalidPositionsNeverInventReleaseData() async throws {
        var song = AppleMusicSongMetadata(id: "456", title: "Catalog title", artist: "Catalog artist")
        song.albumTitle = "Catalog album"
        song.trackNumber = 0
        song.discNumber = -2
        var shazam = catalogShazam()
        shazam.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let response = song
        let matches = try await identifyShazam(using: shazamService(shazam) { _ in response })
        let edition = try XCTUnwrap(matches.first { $0.appleMusicMetadata != nil })
        XCTAssertTrue(edition.tags.year.isEmpty, "Shazam creationDate must not become the release year")
        XCTAssertTrue(edition.tags.trackNumber.isEmpty)
        XCTAssertTrue(edition.tags.discNumber.isEmpty)
        XCTAssertTrue(edition.tags.albumArtist.isEmpty, "The song artist does not establish the album artist")
    }

    func testAppleMusicReleaseYearUsesUTCAndGregorianCalendar() async throws {
        var song = appleSong()
        song.releaseDate = ISO8601DateFormatter().date(from: "1999-12-31T23:59:59Z")!
        let response = song
        let matches = try await identifyShazam(using: shazamService(catalogShazam()) { _ in response })
        XCTAssertEqual(matches.first { $0.appleMusicMetadata != nil }?.tags.year, "1999")
    }

    func testAppleMusicCanSupplyMissingArtistGenreAndCover() async throws {
        var song = appleSong()
        song.genres = ["Jazz"]
        let shazam = ShazamRecognitionResult(id: "123", title: "Shazam title", artist: "", appleMusicID: "456")
        let response = song
        let matches = try await identifyShazam(using: shazamService(shazam) { _ in response })
        let edition = try XCTUnwrap(matches.first { $0.appleMusicMetadata != nil })
        XCTAssertEqual(edition.tags.artist, song.artist)
        XCTAssertEqual(edition.tags.genre, L10n.text("Jazz", "爵士"))
        XCTAssertEqual(edition.artworkURL, song.artworkURL)
    }

    func testAppleMusicRejectsWrongIDAndConflictingKnownRecording() async throws {
        for mismatch in ["id", "isrc"] {
            var song = appleSong()
            if mismatch == "id" { song.id = "789" }
            else { song.isrc = "USAAA2600002" }
            let response = song
            let matches = try await identifyShazam(using: shazamService(catalogShazam()) { _ in response })
            XCTAssertEqual(matches.count, 1)
            XCTAssertNil(matches.first?.appleMusicMetadata)
            XCTAssertTrue(matches.first?.tags.album.isEmpty == true)
            let notice = try XCTUnwrap(matches.first?.supplementationNotice)
            XCTAssertTrue(notice.contains(mismatch == "id"
                ? L10n.text("different song ID", "歌曲标识与请求不一致") : "ISRC"))
        }
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testAppleMusicFailureAndNoMatchKeepSuccessfulShazamRecognition() async throws {
        let cases: [(@Sendable (String) async throws -> AppleMusicSongMetadata?, String)] = [
            ({ _ in nil }, L10n.text("No exact match", "未找到与此歌曲标识完全一致")),
            ({ _ in throw URLError(.notConnectedToInternet) }, "NSURLErrorDomain -1009"),
            ({ _ in throw MusTagError.message("Authorization denied") }, "Authorization denied"),
            ({ _ in throw MusicTokenRequestError.developerTokenRequestFailed }, "MusicKit developerTokenRequestFailed")
        ]
        for (provider, reason) in cases {
            let matches = try await identifyShazam(using: shazamService(catalogShazam(), appleMusicProvider: provider))
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.tags.title, "Shazam title")
            XCTAssertNil(matches.first?.appleMusicMetadata)
            let notice = try XCTUnwrap(matches.first?.supplementationNotice)
            XCTAssertTrue(notice.contains(reason), notice)
            XCTAssertTrue(notice.contains(L10n.text("Shazam tags were kept", "已保留 Shazam 标签")), notice)
        }
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testAppleMusicMissingAlbumHasDistinctReasonAndKeepsBasicMatch() async throws {
        var catalog = appleSong()
        catalog.albumTitle = " "
        let response = catalog
        let matches = try await identifyShazam(using: shazamService(catalogShazam()) { _ in response })
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.tags.title, "Shazam title")
        XCTAssertTrue(matches.first?.tags.album.isEmpty == true)
        XCTAssertTrue(matches.first?.tags.year.isEmpty == true)
        XCTAssertTrue(matches.first?.tags.trackNumber.isEmpty == true)
        let notice = try XCTUnwrap(matches.first?.supplementationNotice)
        XCTAssertTrue(notice.contains(L10n.text("no album name", "未返回专辑名称")))
    }

    func testAppleMusicUnknownFailureDoesNotExposeProviderDetailsInFallback() async throws {
        let error = NSError(domain: "private-domain-secret-token", code: 5678,
                            userInfo: [NSLocalizedDescriptionKey: "private-description secret-token"])
        let matches = try await identifyShazam(using: shazamService(catalogShazam()) { _ in throw error })
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.tags.title, "Shazam title")
        let notice = try XCTUnwrap(matches.first?.supplementationNotice)
        XCTAssertTrue(notice.contains("5678"))
        XCTAssertFalse(notice.contains("private"))
        XCTAssertFalse(notice.contains("secret"))
    }

    func testInvalidAppleMusicIDsDoNotReachProvider() async throws {
        for id in ["", "../456", "456?storefront=us", "not-a-number", "0", "-456"] {
            var shazam = catalogShazam()
            shazam.appleMusicID = id
            let matches = try await identifyShazam(using: shazamService(shazam) { _ in
                XCTFail("Invalid catalog ID must not reach the provider: \(id)")
                return nil
            })
            XCTAssertEqual(matches.count, 1)
            let notice = try XCTUnwrap(matches.first?.supplementationNotice)
            XCTAssertTrue(notice.contains(L10n.text("valid Apple Music song ID", "有效的 Apple Music 歌曲标识")))
        }
        XCTAssertEqual(RecognitionURLProtocol.requestCount, 0)
    }

    func testAppleMusicCancellationPropagatesInsteadOfApplyingPartialResult() async throws {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            do {
                _ = try await identifyShazam(using: shazamService(catalogShazam()) { _ in throw error })
                XCTFail("Cancelling catalog lookup must not apply partial tags")
            } catch is CancellationError { }
        }
    }

    func testDifferentShazamMatchesRemainAmbiguousDespiteCatalogAlbumPreference() async throws {
        var second = catalogShazam()
        second.id = "other-shazam-song"
        second.appleMusicID = "789"
        let first = catalogShazam()
        let secondMatch = second
        let song = appleSong()
        let service = MusicRecognitionService(session: session(), shazamProvider: { _ in [first, secondMatch] },
            appleMusicProvider: { id in
                var response = song
                response.id = id
                return response
            })
        let matches = try await identifyShazam(using: service)
        guard case .ambiguous = MusicRecognitionService.automaticMatch(from: matches, originalAlbum: "Catalog album") else {
            return XCTFail("Album preference cannot choose between distinct Shazam identities")
        }
    }

    private func candidate(_ id: String, score: Double?, album: String = "") -> MetadataCandidate {
        MetadataCandidate(id: id, tags: AudioTags(title: "Song", album: album), score: score,
                          detail: "", source: .acoustID)
    }

    private func catalogShazam() -> ShazamRecognitionResult {
        .init(id: "123", title: "Shazam title", artist: "Shazam artist", isrc: "USAAA2600001", appleMusicID: "456")
    }

    private func appleSong() -> AppleMusicSongMetadata {
        var song = AppleMusicSongMetadata(id: "456", title: "Catalog title", artist: "Catalog artist")
        song.albumTitle = "Catalog album"
        song.albumArtist = "Album artist"
        song.releaseDate = ISO8601DateFormatter().date(from: "1998-04-05T00:00:00Z")!
        song.trackNumber = 7
        song.discNumber = 2
        song.isrc = "USAAA2600001"
        song.duration = 210
        song.url = URL(string: "https://music.apple.com/us/song/456")
        song.artworkURL = URL(string: "https://is1-ssl.mzstatic.com/catalog.jpg")
        song.genres = ["Jazz"]
        return song
    }

    private func shazamService(_ match: ShazamRecognitionResult,
                              appleMusicProvider: @escaping @Sendable (String) async throws -> AppleMusicSongMetadata? = { _ in nil }) -> MusicRecognitionService {
        MusicRecognitionService(session: session(), shazamProvider: { _ in [match] },
                                appleMusicProvider: appleMusicProvider)
    }

    private func temporaryAudio() throws -> URL {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("local audio fixture".utf8).write(to: source)
        return source
    }

    private func identifyShazam(using service: MusicRecognitionService) async throws -> [MetadataCandidate] {
        let source = try temporaryAudio()
        defer { try? FileManager.default.removeItem(at: source) }
        return try await service.identify(url: source, apiKey: "", provider: .shazamKit)
    }

    private func identificationError(status: Int, body: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.mp3")
        try Data("private audio content".utf8).write(to: source)
        RecognitionURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.acoustid.org", "Failed lookups must not query another provider")
            XCTAssertEqual(request.url?.path, "/v2/lookup")
            return (status, Data(body.utf8))
        }
        let initialRequestCount = RecognitionURLProtocol.requestCount
        let service = MusicRecognitionService(session: session(), minimumAcoustIDInterval: 0, fingerprintProvider: { _ in ("test-fingerprint", 120.6) })
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

private actor ShazamStagedFile {
    var url: URL?
    func record(_ url: URL) { self.url = url }
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
