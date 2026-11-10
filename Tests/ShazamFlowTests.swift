import UIKit
import XCTest
@testable import MusTag

final class ShazamFlowTests: XCTestCase {
    private let artworkURL = URL(string: "https://is1-ssl.mzstatic.com/image/recognized-cover.png")!

    override func tearDown() {
        ShazamFlowURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultShazamNeedsNoKeyAndKeepsFieldsMissingFromRecognition() async throws {
        let match = ShazamRecognitionResult(id: "101", title: "Recognized title", artist: "")
        let context = try await context(matches: [match])
        defer { context.cleanUp() }
        XCTAssertEqual(context.model.recognitionProvider, .shazamKit)
        XCTAssertFalse(context.model.hasAPIKey)

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, context.document.original.artist)
        XCTAssertEqual(document.draft.album, context.document.original.album)
        XCTAssertEqual(document.draft.albumArtist, context.document.original.albumArtist)
        XCTAssertEqual(document.draft.year, context.document.original.year)
        XCTAssertEqual(document.draft.trackNumber, context.document.original.trackNumber)
        XCTAssertEqual(document.draft.discNumber, context.document.original.discNumber)
        XCTAssertEqual(document.draft.genre, context.document.original.genre)
        XCTAssertEqual(document.draftArtwork, context.document.originalArtwork)
        let candidate = try XCTUnwrap(context.model.candidates[document.id]?.first)
        XCTAssertTrue(candidate.source == .shazamKit)
        XCTAssertNil(candidate.score, "Shazam results must not fabricate an AcoustID similarity score")
        XCTAssertEqual(context.model.appliedCandidateIDs[document.id], candidate.id)
        XCTAssertEqual(context.model.selectedTab, .home)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testExplicitShazamAddsTagsAndCoverToPersistentDraftOnly() async throws {
        let appleMusicURL = try XCTUnwrap(URL(string: "https://music.apple.com/us/album/example/123?i=456"))
        let match = ShazamRecognitionResult(id: "102", title: "Identified song", artist: "Matched artist",
                                           genres: ["Pop"], isrc: "USAAA2600001", artworkURL: artworkURL,
                                           appleMusicURL: appleMusicURL)
        let context = try await context(matches: [match], provider: .shazamKit)
        defer { context.cleanUp() }
        let downloaded = try artwork(color: .blue)
        let expectedURL = artworkURL
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, expectedURL, "The matched artwork URL must be used unchanged")
            return .init(status: 200, data: downloaded.data)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, match.artist)
        XCTAssertEqual(document.draft.genre, L10n.text("Pop", "流行"))
        XCTAssertEqual(document.draftArtwork, downloaded)
        XCTAssertNotNil(document.error, "Missing catalog data should remain visible without losing the Shazam match")
        let candidate = try XCTUnwrap(context.model.candidates[document.id]?.first)
        XCTAssertEqual(candidate.appleMusicURL, appleMusicURL)
        XCTAssertEqual(candidate.isrc, match.isrc)
        XCTAssertNil(candidate.score)
        let attribution = ShazamAttribution(title: match.title, artist: match.artist,
                                           appleMusicURL: appleMusicURL, metadata: match)
        XCTAssertEqual(document.draftShazamAttribution, attribution)
        XCTAssertNil(document.originalShazamAttribution)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, document.draft)
        XCTAssertEqual(persisted.documents.first?.draftArtwork, downloaded)
        XCTAssertEqual(persisted.documents.first?.draftShazamAttribution, attribution)
        let reopened = AppModel(fileStore: context.store, preferences: context.preferences)
        await reopened.load()
        XCTAssertEqual(reopened.document(document.id)?.draftShazamAttribution, attribution,
                       "Restarting the app must not lose the attribution link")
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testMissingAndFailedShazamCoversKeepOriginalArtworkWhileApplyingText() async throws {
        for status in [404, 503] {
            let match = ShazamRecognitionResult(id: "103", title: "Recognized title", artist: "Matched artist",
                                               artworkURL: artworkURL)
            let context = try await context(matches: [match])
            defer { context.cleanUp() }
            ShazamFlowURLProtocol.handler = { request in
                XCTAssertEqual(request.url, self.artworkURL)
                return .init(status: status, data: Data())
            }

            context.model.identify([context.document.id], automaticallyApply: true)
            try await waitUntilIdle(context.model)

            let document = try XCTUnwrap(context.model.document(context.document.id))
            XCTAssertEqual(document.draft.title, match.title, "HTTP \(status)")
            XCTAssertEqual(document.draftArtwork, context.document.originalArtwork, "HTTP \(status)")
            XCTAssertNotNil(document.error)
            XCTAssertNotNil(context.model.appliedCandidateIDs[document.id])
            try await assertOriginalUntouched(context)
        }
    }

    @MainActor
    func testNoMatchAndAmbiguousMatchesPreserveExistingDraft() async throws {
        let matches = [ShazamRecognitionResult(id: "104", title: "First song", artist: "Artist"),
                       ShazamRecognitionResult(id: "105", title: "Second song", artist: "Artist")]
        for results in [[], matches] {
            let context = try await context(matches: results)
            defer { context.cleanUp() }
            var draft = context.document.draft
            draft.title = "My unsaved edit"
            context.model.updateDraft(draft, for: context.document.id)

            context.model.identify([context.document.id], automaticallyApply: true)
            try await waitUntilIdle(context.model)

            let document = try XCTUnwrap(context.model.document(context.document.id))
            XCTAssertEqual(document.draft, draft)
            XCTAssertEqual(document.draftArtwork, context.document.draftArtwork)
            XCTAssertEqual(context.model.candidates[document.id]?.count, results.count)
            XCTAssertNil(context.model.appliedCandidateIDs[document.id])
            XCTAssertNotNil(document.error)
            let persisted = try await context.store.loadLibrary()
            XCTAssertEqual(persisted.documents.first?.draft, draft)
            try await assertOriginalUntouched(context)
        }
    }

    @MainActor
    func testAmbiguousShazamMatchCanBeSelectedManually() async throws {
        let matches = [ShazamRecognitionResult(id: "106", title: "First song", artist: "Artist"),
                       ShazamRecognitionResult(id: "107", title: "Second song", artist: "Artist")]
        let context = try await context(matches: matches)
        defer { context.cleanUp() }
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        let chosen = try XCTUnwrap(context.model.candidates[context.document.id]?.last)

        context.model.useCandidate(chosen, for: context.document.id)
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(context.document.id)?.draft.title, "Second song")
        XCTAssertEqual(context.model.appliedCandidateIDs[context.document.id], chosen.id)
        XCTAssertNil(chosen.score)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testCancellationWhileRecognizingKeepsPriorDraft() async throws {
        let started = expectation(description: "Shazam recognition started")
        let match = ShazamRecognitionResult(id: "108", title: "Should not apply", artist: "Artist")
        let context = try await context(matches: [], shazamProvider: { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return [match]
        })
        defer { context.cleanUp() }
        var draft = context.document.draft
        draft.title = "Keep this edit"
        context.model.updateDraft(draft, for: context.document.id)

        context.model.identify([context.document.id], automaticallyApply: true)
        await fulfillment(of: [started], timeout: 3)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(context.document.id)?.draft, draft)
        XCTAssertEqual(context.model.document(context.document.id)?.draftArtwork, context.document.draftArtwork)
        XCTAssertNil(context.model.appliedCandidateIDs[context.document.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, draft)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testCancellationWhileDownloadingShazamCoverKeepsPriorTagsAndArtwork() async throws {
        let match = ShazamRecognitionResult(id: "109", title: "Should not apply", artist: "Artist",
                                           artworkURL: artworkURL)
        let context = try await context(matches: [match])
        defer { context.cleanUp() }
        var draft = context.document.draft
        draft.title = "Keep this edit"
        context.model.updateDraft(draft, for: context.document.id)
        let previousCover = try artwork(color: .green)
        context.model.documents[0].draftArtwork = previousCover
        let started = expectation(description: "Shazam cover started")
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, self.artworkURL)
            started.fulfill()
            return .init(status: 200, data: Data(), stalls: true)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        await fulfillment(of: [started], timeout: 3)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft, draft)
        XCTAssertEqual(document.draftArtwork, previousCover)
        XCTAssertNil(context.model.appliedCandidateIDs[document.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draftArtwork, previousCover)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testProviderChoicePersistsAndExplicitChoiceOverridesSavedPreference() async throws {
        let context = try await context(matches: [])
        defer { context.cleanUp() }
        XCTAssertEqual(context.model.recognitionProvider, .shazamKit)
        context.model.recognitionProvider = .acoustID
        let restored = AppModel(fileStore: context.store, preferences: context.preferences)
        XCTAssertEqual(restored.recognitionProvider, .acoustID)
        let explicit = AppModel(fileStore: context.store, recognitionProvider: .shazamKit,
                                preferences: context.preferences)
        XCTAssertEqual(explicit.recognitionProvider, .shazamKit)
        context.preferences.set("unknown-future-provider", forKey: "recognitionProvider")
        let recovered = AppModel(fileStore: context.store, preferences: context.preferences)
        XCTAssertEqual(recovered.recognitionProvider, .shazamKit)
    }

    @MainActor
    func testConfirmedShazamDraftSavesWithBackupAndPreservesAudioThenRestores() async throws {
        let previousMatch = ShazamRecognitionResult(id: "previous", title: "Original title", artist: "Original artist",
            appleMusicID: "100", explicitContent: false)
        let previousAttribution = ShazamAttribution(title: "Original title", artist: "Original artist",
            appleMusicURL: URL(string: "https://music.apple.com/us/song/original/100"), metadata: previousMatch)
        let match = ShazamRecognitionResult(id: "110", title: "Saved recognition", artist: "Matched artist",
            isrc: "USAAA2600001", artworkURL: artworkURL,
            appleMusicURL: URL(string: "https://music.apple.com/us/song/new/110"),
            subtitle: "Live performance", appleMusicID: "110",
            webURL: URL(string: "https://www.shazam.com/track/110/song"),
            videoURL: URL(string: "https://example.com/video"), explicitContent: true,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            timeRanges: [2..<8], frequencySkewRanges: [0.95..<1.05],
            matchOffset: 12, frequencySkew: 1.01, predictedCurrentMatchOffset: 14)
        let song = appleSong(id: "110")
        let expectedAttribution = ShazamAttribution(title: match.title, artist: match.artist,
            appleMusicURL: match.appleMusicURL, metadata: match, appleMusicMetadata: song)
        let context = try await context(matches: [match], appleMusicProvider: { _ in song },
                                        originalAttribution: previousAttribution, originalAlbum: "")
        defer { context.cleanUp() }
        let downloaded = try artwork(color: .blue)
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            return .init(status: 200, data: downloaded.data)
        }
        let originalAudioHash = try NativeAudio.payloadHash(url: context.source)
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        try await assertOriginalUntouched(context)

        context.model.save([context.document.id])
        try await waitUntilIdle(context.model)

        let saved = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertFalse(saved.hasChanges)
        XCTAssertEqual(saved.original.title, match.title)
        XCTAssertEqual(saved.originalShazamAttribution, expectedAttribution)
        XCTAssertEqual(saved.draftShazamAttribution, expectedAttribution)
        let snapshot = try NativeMetadataCodec().read(from: saved.url)
        XCTAssertEqual(snapshot.tags.title, match.title)
        XCTAssertEqual(snapshot.tags.album, "Catalog album")
        XCTAssertEqual(snapshot.tags.year, "1998", "The Shazam item's creation date must not become the release year")
        XCTAssertEqual(snapshot.tags.trackNumber, "7")
        XCTAssertEqual(snapshot.tags.discNumber, "2")
        XCTAssertEqual(snapshot.artwork, downloaded)
        XCTAssertEqual(try NativeAudio.payloadHash(url: saved.url), originalAudioHash)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        let backups = try await context.store.backups()
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertNotNil(backup.backupHash)
        XCTAssertEqual(backup.backupURL.pathExtension, "mustagbackup")
        let archive = try AudioMetadataBackup(data: Data(contentsOf: backup.backupURL))
        XCTAssertEqual(archive.originalFileSize, UInt64(context.originalBytes.count))
        XCTAssertLessThan(try Data(contentsOf: backup.backupURL).count, context.originalBytes.count)
        XCTAssertEqual(backup.originalShazamAttribution, previousAttribution)
        let reopened = AppModel(fileStore: context.store, preferences: context.preferences)
        await reopened.load()
        XCTAssertEqual(reopened.document(saved.id)?.originalShazamAttribution, expectedAttribution)

        context.model.restore(backup)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        XCTAssertEqual(try Data(contentsOf: saved.url), context.originalBytes)
        XCTAssertEqual(context.model.document(context.document.id)?.original, context.document.original)
        XCTAssertEqual(context.model.document(context.document.id)?.originalArtwork, context.document.originalArtwork)
        XCTAssertEqual(context.model.document(context.document.id)?.originalShazamAttribution, previousAttribution)
        XCTAssertEqual(context.model.document(context.document.id)?.draftShazamAttribution, previousAttribution)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.originalShazamAttribution, previousAttribution)
    }

    @MainActor
    func testLocalizedShazamGenreMatchesDraftSavedFileAndRestoresOriginal() async throws {
        let match = ShazamRecognitionResult(id: "111", title: "Original title", artist: "Original artist",
                                           genres: ["国语流行", "音乐", "国际流行"])
        let context = try await context(matches: [match])
        defer { context.cleanUp() }
        let expectedGenre = L10n.text("Mandopop; Music; Pop", "国语流行; 音乐; 流行")
        let originalAudioHash = try NativeAudio.payloadHash(url: context.source)

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let draft = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(context.model.candidates[draft.id]?.first?.tags.genre, expectedGenre)
        XCTAssertEqual(TagField.genre.value(in: draft.draft), expectedGenre,
                       "The review sheet must show the same genre that will be written")
        var expectedTags = context.document.original
        expectedTags.genre = expectedGenre
        XCTAssertEqual(draft.draft, expectedTags, "Genre localization must not change unrelated tags")
        let pendingLibrary = try await context.store.loadLibrary()
        XCTAssertEqual(pendingLibrary.documents.first?.draft.genre, expectedGenre)
        try await assertOriginalUntouched(context)

        context.model.save([draft.id])
        try await waitUntilIdle(context.model)

        let saved = try XCTUnwrap(context.model.document(draft.id))
        XCTAssertFalse(saved.hasChanges)
        XCTAssertEqual(saved.original.genre, expectedGenre)
        XCTAssertEqual(try NativeMetadataCodec().read(from: saved.url).tags.genre, expectedGenre)
        XCTAssertEqual(try NativeAudio.payloadHash(url: saved.url), originalAudioHash)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        let savedLibrary = try await context.store.loadLibrary()
        XCTAssertEqual(savedLibrary.documents.first?.original.genre, expectedGenre)
        let backups = try await context.store.backups()
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)

        context.model.restore(backup)
        try await waitUntilIdle(context.model)

        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        XCTAssertEqual(try NativeMetadataCodec().read(from: saved.url).tags.genre, context.document.original.genre)
        XCTAssertEqual(try Data(contentsOf: saved.url), context.originalBytes)
        XCTAssertEqual(context.model.document(draft.id)?.draft.genre, context.document.original.genre)
    }

    @MainActor
    func testAppleMusicCompletesAlbumYearAndPositionInPersistentDraftOnly() async throws {
        let match = ShazamRecognitionResult(id: "112", title: "Shazam title", artist: "Shazam artist",
            genres: ["Pop"], isrc: "USAAA2600001", artworkURL: artworkURL,
            appleMusicURL: URL(string: "https://music.apple.com/us/song/456"), appleMusicID: "456")
        let song = appleSong()
        let context = try await context(matches: [match], appleMusicProvider: { id in
            XCTAssertEqual(id, "456")
            return song
        }, originalAlbum: "")
        defer { context.cleanUp() }
        let downloaded = try artwork(color: .blue)
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL, "The selected catalog edition supplies its own cover")
            return .init(status: 200, data: downloaded.data)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, match.artist)
        XCTAssertEqual(document.draft.genre, L10n.text("Pop", "流行"))
        XCTAssertEqual(document.draft.album, "Catalog album")
        XCTAssertEqual(document.draft.albumArtist, "Album artist")
        XCTAssertEqual(document.draft.year, "1998")
        XCTAssertEqual(document.draft.trackNumber, "7")
        XCTAssertEqual(document.draft.discNumber, "2")
        XCTAssertEqual(document.draftArtwork, downloaded)
        XCTAssertEqual(document.draftShazamAttribution?.metadata, match)
        XCTAssertEqual(document.draftShazamAttribution?.appleMusicMetadata, song)
        XCTAssertEqual(context.model.candidates[document.id]?.count, 1,
                       "The recognized song and its catalog details must be one candidate")
        XCTAssertEqual(context.model.appliedReleaseChoices[document.id], .appleMusic)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, document.draft)
        XCTAssertEqual(persisted.documents.first?.draftShazamAttribution?.appleMusicMetadata, song)
        XCTAssertEqual(ShazamFlowURLProtocol.requests.count, 1)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testMissingShazamCoverUsesOnlyTheSelectedAppleMusicArtwork() async throws {
        let match = ShazamRecognitionResult(id: "113", title: "Shazam title", artist: "Shazam artist",
                                           appleMusicID: "456")
        let song = appleSong()
        let context = try await context(matches: [match], appleMusicProvider: { _ in song }, originalAlbum: "")
        defer { context.cleanUp() }
        let downloaded = try artwork(color: .blue)
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            return .init(status: 200, data: downloaded.data)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.album, song.albumTitle)
        XCTAssertEqual(document.draftArtwork, downloaded)
        XCTAssertEqual(ShazamFlowURLProtocol.requests.count, 1)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testAppleMusicFailureRetainsRecognizedSongAndExistingReleaseFields() async throws {
        let match = ShazamRecognitionResult(id: "114", title: "Shazam title", artist: "Shazam artist",
                                           genres: ["Pop"], appleMusicID: "456")
        let context = try await context(matches: [match], appleMusicProvider: { _ in
            throw URLError(.notConnectedToInternet)
        })
        defer { context.cleanUp() }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, match.artist)
        XCTAssertEqual(document.draft.album, context.document.original.album)
        XCTAssertEqual(document.draft.year, context.document.original.year)
        XCTAssertEqual(document.draft.trackNumber, context.document.original.trackNumber)
        XCTAssertEqual(document.draft.discNumber, context.document.original.discNumber)
        XCTAssertEqual(document.draftArtwork, context.document.originalArtwork)
        XCTAssertNotNil(document.error)
        XCTAssertEqual(document.draftShazamAttribution?.metadata, match)
        XCTAssertNil(document.draftShazamAttribution?.appleMusicMetadata)
        XCTAssertTrue(ShazamFlowURLProtocol.requests.isEmpty)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testDifferentAlbumUsesOneCandidateAndExplicitReleaseChoicesAreReversible() async throws {
        let match = ShazamRecognitionResult(id: "115", title: "Shazam title", artist: "Shazam artist",
                                           genres: ["Pop"], artworkURL: artworkURL, appleMusicID: "456")
        var catalog = appleSong()
        catalog.discNumber = 1
        let song = catalog
        let context = try await context(matches: [match], appleMusicProvider: { _ in song })
        defer { context.cleanUp() }
        let catalogArtwork = try artwork(color: .green)
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            return .init(status: 200, data: catalogArtwork.data)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let initial = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(initial.draft.title, match.title)
        XCTAssertEqual(initial.draft.album, context.document.original.album)
        XCTAssertEqual(initial.draft.albumArtist, context.document.original.albumArtist)
        XCTAssertEqual(initial.draft.year, context.document.original.year)
        XCTAssertEqual(initial.draft.trackNumber, context.document.original.trackNumber)
        XCTAssertEqual(initial.draft.discNumber, context.document.original.discNumber)
        XCTAssertNil(initial.error, "Album choices are presented in the candidate, not as a failed lookup")
        XCTAssertEqual(initial.draftArtwork, context.document.originalArtwork)
        XCTAssertEqual(initial.draftShazamAttribution?.appleMusicMetadata, song)
        XCTAssertTrue(ShazamFlowURLProtocol.requests.isEmpty)
        XCTAssertEqual(context.model.candidates[initial.id]?.count, 1)
        let chosen = try XCTUnwrap(context.model.candidates[initial.id]?.first)
        XCTAssertEqual(chosen.appleMusicMetadata, song)
        XCTAssertEqual(context.model.appliedCandidateIDs[initial.id], chosen.id)
        XCTAssertNil(context.model.appliedReleaseChoices[initial.id], "The album choice still needs an explicit decision")

        context.model.useCandidate(chosen, for: initial.id, releaseChoice: .appleMusic)
        try await waitUntilIdle(context.model)

        let selected = try XCTUnwrap(context.model.document(initial.id))
        XCTAssertEqual(selected.draft.title, match.title)
        XCTAssertEqual(selected.draft.artist, match.artist)
        XCTAssertEqual(selected.draft.genre, L10n.text("Pop", "流行"))
        XCTAssertEqual(selected.draft.album, "Catalog album")
        XCTAssertEqual(selected.draft.albumArtist, "Album artist")
        XCTAssertEqual(selected.draft.year, "1998")
        XCTAssertEqual(selected.draft.trackNumber, "7")
        XCTAssertEqual(selected.draft.discNumber, "1")
        XCTAssertEqual(selected.draftArtwork, catalogArtwork)
        XCTAssertEqual(selected.draftShazamAttribution?.appleMusicMetadata, song)
        XCTAssertEqual(context.model.appliedCandidateIDs[selected.id], chosen.id)
        XCTAssertEqual(context.model.appliedReleaseChoices[selected.id], .appleMusic)
        XCTAssertEqual(ShazamFlowURLProtocol.requests.map(\.url), [song.artworkURL])

        context.model.useCandidate(chosen, for: selected.id, releaseChoice: .keepOriginal)
        try await waitUntilIdle(context.model)

        let restored = try XCTUnwrap(context.model.document(selected.id))
        var expected = context.document.original
        expected.title = match.title
        expected.artist = match.artist
        expected.genre = L10n.text("Pop", "流行")
        XCTAssertEqual(restored.draft, expected,
                       "Keeping the original edition must undo all catalog release fields, not merge into them")
        XCTAssertEqual(restored.draftArtwork, context.document.originalArtwork)
        XCTAssertEqual(restored.draftShazamAttribution?.appleMusicMetadata, song)
        XCTAssertEqual(context.model.appliedCandidateIDs[restored.id], chosen.id)
        XCTAssertEqual(context.model.appliedReleaseChoices[restored.id], .keepOriginal)
        XCTAssertEqual(context.model.candidates[restored.id]?.count, 1)
        XCTAssertEqual(ShazamFlowURLProtocol.requests.map(\.url), [song.artworkURL],
                       "Keeping original release information must not download a replacement cover")
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, expected)
        XCTAssertEqual(persisted.documents.first?.draftArtwork, context.document.originalArtwork)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testAlbumConflictPreservesPendingReleaseEditsUntilExplicitChoice() async throws {
        let match = ShazamRecognitionResult(id: "118", title: "Shazam title", artist: "Shazam artist",
                                           genres: ["Pop"], artworkURL: artworkURL, appleMusicID: "456")
        let song = appleSong()
        let context = try await context(matches: [match], appleMusicProvider: { _ in song })
        defer { context.cleanUp() }
        var draft = context.document.draft
        draft.album = "My pending album"
        draft.albumArtist = "My pending album artist"
        draft.year = "2005"
        draft.trackNumber = "12"
        draft.discNumber = "4"
        context.model.updateDraft(draft, for: context.document.id)
        let pendingCover = try artwork(color: .yellow)
        context.model.documents[0].draftArtwork = pendingCover

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        let chosen = try XCTUnwrap(context.model.candidates[context.document.id]?.first)
        context.model.useCandidate(chosen, for: context.document.id)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        draft.title = match.title
        draft.artist = match.artist
        draft.genre = L10n.text("Pop", "流行")
        XCTAssertEqual(document.draft, draft,
                       "Neither automatic matching nor default selection should replace pending release edits")
        XCTAssertEqual(document.draftArtwork, pendingCover)
        XCTAssertNil(context.model.appliedReleaseChoices[document.id])
        XCTAssertTrue(ShazamFlowURLProtocol.requests.isEmpty)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, draft)
        XCTAssertEqual(persisted.documents.first?.draftArtwork, pendingCover)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testKeepingOriginalReleaseRestoresOriginallyEmptyFields() async throws {
        let match = ShazamRecognitionResult(id: "119", title: "Shazam title", artist: "Shazam artist",
                                           appleMusicID: "456")
        let song = appleSong()
        let original = AudioTags(title: "Original title", artist: "Original artist", album: "Original album")
        let context = try await context(matches: [match], appleMusicProvider: { _ in song }, originalTags: original)
        defer { context.cleanUp() }
        let catalogArtwork = try artwork(color: .green)
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            return .init(status: 200, data: catalogArtwork.data)
        }
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        let chosen = try XCTUnwrap(context.model.candidates[context.document.id]?.first)

        context.model.useCandidate(chosen, for: context.document.id, releaseChoice: .appleMusic)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(context.model.document(context.document.id)?.draft.year, "1998")
        context.model.useCandidate(chosen, for: context.document.id, releaseChoice: .keepOriginal)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.album, original.album)
        XCTAssertEqual(document.draft.albumArtist, "")
        XCTAssertEqual(document.draft.year, "")
        XCTAssertEqual(document.draft.trackNumber, "")
        XCTAssertEqual(document.draft.discNumber, "")
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, match.artist)
        XCTAssertEqual(document.draftArtwork, context.document.originalArtwork)
        XCTAssertEqual(context.model.appliedReleaseChoices[document.id], .keepOriginal)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testCancellingCatalogCoverKeepsPreviousExplicitReleaseChoice() async throws {
        let match = ShazamRecognitionResult(id: "120", title: "Shazam title", artist: "Shazam artist",
                                           appleMusicID: "456")
        let song = appleSong()
        let context = try await context(matches: [match], appleMusicProvider: { _ in song })
        defer { context.cleanUp() }
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        let chosen = try XCTUnwrap(context.model.candidates[context.document.id]?.first)
        context.model.useCandidate(chosen, for: context.document.id, releaseChoice: .keepOriginal)
        try await waitUntilIdle(context.model)
        let before = try XCTUnwrap(context.model.document(context.document.id))
        let started = expectation(description: "Catalog cover started")
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            started.fulfill()
            return .init(status: 200, data: Data(), stalls: true)
        }

        context.model.useCandidate(chosen, for: before.id, releaseChoice: .appleMusic)
        await fulfillment(of: [started], timeout: 3)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        let after = try XCTUnwrap(context.model.document(before.id))
        XCTAssertEqual(after.draft, before.draft)
        XCTAssertEqual(after.draftArtwork, before.draftArtwork)
        XCTAssertEqual(after.draftShazamAttribution, before.draftShazamAttribution)
        XCTAssertEqual(context.model.appliedCandidateIDs[after.id], chosen.id)
        XCTAssertEqual(context.model.appliedReleaseChoices[after.id], .keepOriginal)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, before.draft)
        XCTAssertEqual(persisted.documents.first?.draftArtwork, before.draftArtwork)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testCancellingImmediateCatalogSelectionPersistsPendingManualEdits() async throws {
        let match = ShazamRecognitionResult(id: "121", title: "Shazam title", artist: "Shazam artist",
                                           appleMusicID: "456")
        let song = appleSong()
        let context = try await context(matches: [match], appleMusicProvider: { _ in song })
        defer { context.cleanUp() }
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(context.model.candidates[context.document.id]?.count, 1)
        let chosen = try XCTUnwrap(context.model.candidates[context.document.id]?.first)
        let before = try XCTUnwrap(context.model.document(context.document.id))
        let started = expectation(description: "Catalog cover started before manual edits were persisted")
        ShazamFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.url, song.artworkURL)
            started.fulfill()
            return .init(status: 200, data: Data(), stalls: true)
        }
        var manualDraft = before.draft
        manualDraft.title = "My unsaved title"
        manualDraft.album = "My unsaved album"
        manualDraft.year = "2005"

        // Keep both calls in the same MainActor turn, before the persistence debounce can run.
        context.model.updateDraft(manualDraft, for: before.id)
        context.model.useCandidate(chosen, for: before.id, releaseChoice: .appleMusic)
        await fulfillment(of: [started], timeout: 3)
        let duringDownload = try await context.store.loadLibrary()
        XCTAssertEqual(duringDownload.documents.first?.draft, before.draft,
                       "This exercises cancellation while the manual edits are still only in memory")
        XCTAssertNotEqual(duringDownload.documents.first?.draft, manualDraft)

        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        let after = try XCTUnwrap(context.model.document(before.id))
        XCTAssertEqual(after.draft, manualDraft)
        XCTAssertEqual(after.draftArtwork, before.draftArtwork)
        XCTAssertEqual(after.draftShazamAttribution, before.draftShazamAttribution)
        XCTAssertNil(context.model.appliedCandidateIDs[after.id])
        XCTAssertNil(context.model.appliedReleaseChoices[after.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, manualDraft,
                       "Cancelling a selection must persist edits whose debounce was cancelled by begin()")
        XCTAssertEqual(persisted.documents.first?.draftArtwork, before.draftArtwork)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testUnavailableCatalogFieldsDoNotEraseExistingTags() async throws {
        let match = ShazamRecognitionResult(id: "116", title: "Shazam title", artist: "Shazam artist", appleMusicID: "456")
        let song = AppleMusicSongMetadata(id: "456", title: "Catalog title", artist: "Catalog artist",
                                          albumTitle: "Original album")
        let context = try await context(matches: [match], appleMusicProvider: { _ in song })
        defer { context.cleanUp() }
        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.albumArtist, context.document.original.albumArtist)
        XCTAssertEqual(document.draft.year, context.document.original.year)
        XCTAssertEqual(document.draft.trackNumber, context.document.original.trackNumber)
        XCTAssertEqual(document.draft.discNumber, context.document.original.discNumber)
        try await assertOriginalUntouched(context)
    }

    @MainActor
    func testCancellationDuringAppleMusicSupplementationKeepsPriorDraft() async throws {
        let match = ShazamRecognitionResult(id: "117", title: "Should not apply", artist: "Shazam artist", appleMusicID: "456")
        let started = expectation(description: "Apple Music lookup started")
        let context = try await context(matches: [match], appleMusicProvider: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return nil
        })
        defer { context.cleanUp() }
        var draft = context.document.draft
        draft.title = "My pending edit"
        context.model.updateDraft(draft, for: context.document.id)

        context.model.identify([context.document.id], automaticallyApply: true)
        await fulfillment(of: [started], timeout: 3)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft, draft)
        XCTAssertEqual(document.draftArtwork, context.document.draftArtwork)
        XCTAssertNil(document.draftShazamAttribution)
        XCTAssertNil(context.model.appliedCandidateIDs[document.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.draft, draft)
        XCTAssertTrue(ShazamFlowURLProtocol.requests.isEmpty)
        try await assertOriginalUntouched(context)
    }

    func testAlbumConflictIgnoresFormattingButKeepsEditionDifferences() {
        var candidate = MetadataCandidate(id: "shazam:appleMusic:456",
            tags: AudioTags(title: "Song", album: "Catalog album"), detail: "", source: .shazamKit,
            appleMusicMetadata: appleSong())
        for album in ["", " \n\t", "Catalog album", "  CATALOG\t album \n"] {
            XCTAssertFalse(candidate.hasAlbumConflict(with: album), album)
        }
        for album in ["Different album", "Catalog album (Deluxe)", "Catalog album - Live"] {
            XCTAssertTrue(candidate.hasAlbumConflict(with: album), album)
        }
        candidate.tags.album = "Caf\u{00E9}"
        XCTAssertFalse(candidate.hasAlbumConflict(with: "Cafe\u{0301}"),
                       "Equivalent Unicode spellings must not create an album choice")
        candidate.tags.album = ""
        XCTAssertFalse(candidate.hasAlbumConflict(with: "Original album"))
        candidate.tags.album = "Catalog album"
        candidate.appleMusicMetadata = nil
        XCTAssertFalse(candidate.hasAlbumConflict(with: "Original album"),
                       "A basic Shazam result has no catalog release to choose")
        candidate.appleMusicMetadata = appleSong()
        candidate.source = .acoustID
        XCTAssertFalse(candidate.hasAlbumConflict(with: "Original album"))
    }

    func testExistingAttributionWithoutExtendedMetadataStillDecodes() throws {
        let json = Data(#"{"title":"Song","artist":"Artist","appleMusicURL":"https://music.apple.com/us/song/456"}"#.utf8)
        let attribution = try JSONDecoder().decode(ShazamAttribution.self, from: json)
        XCTAssertEqual(attribution.title, "Song")
        XCTAssertNil(attribution.metadata)
        XCTAssertNil(attribution.appleMusicMetadata)
    }

    private func appleSong(id: String = "456") -> AppleMusicSongMetadata {
        var song = AppleMusicSongMetadata(id: id, title: "Catalog title", artist: "Catalog artist")
        song.albumTitle = "Catalog album"
        song.albumArtist = "Album artist"
        song.releaseDate = ISO8601DateFormatter().date(from: "1998-04-05T00:00:00Z")!
        song.trackNumber = 7
        song.discNumber = 2
        song.isrc = "USAAA2600001"
        song.artworkURL = URL(string: "https://is1-ssl.mzstatic.com/catalog-cover.png")
        return song
    }

    @MainActor
    private func context(matches: [ShazamRecognitionResult], provider: RecognitionProvider? = nil,
                         shazamProvider: MusicRecognitionService.ShazamProvider? = nil,
                         appleMusicProvider: @escaping @Sendable (String) async throws -> AppleMusicSongMetadata? = { _ in nil },
                         originalAttribution: ShazamAttribution? = nil,
                         originalAlbum: String = "Original album",
                         originalTags: AudioTags? = nil) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShazamFlow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.m4a")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "m4a", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: source)
        let codec = NativeMetadataCodec()
        try codec.write(originalTags ?? AudioTags(title: "Original title", artist: "Original artist", album: originalAlbum,
                                  albumArtist: "Original album artist", year: "2001", trackNumber: "3",
                                  discNumber: "2", genre: "Local genre"), to: source)
        try codec.writeArtwork(artwork(color: .red), to: source)
        let store = AudioFileStore(codec: codec, storageDirectory: root.appendingPathComponent("State"))
        let imported = try await store.importFiles(from: [source])
        var document = try XCTUnwrap(imported.documents.first, imported.failures.joined(separator: "; "))
        document.originalShazamAttribution = originalAttribution
        document.draftShazamAttribution = originalAttribution
        try await store.persistLibrary(AudioLibrary(documents: [document], folders: []))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShazamFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recognize: MusicRecognitionService.ShazamProvider = shazamProvider ?? { _ in matches }
        let recognition = MusicRecognitionService(session: session, minimumAcoustIDInterval: 0, fingerprintProvider: { _ in
                XCTFail("Selecting Shazam must not run AcoustID fingerprinting")
                throw URLError(.unsupportedURL)
            }, shazamProvider: recognize, appleMusicProvider: appleMusicProvider)
        ShazamFlowURLProtocol.handler = { request in
            XCTFail("Unexpected network request: \(request.url?.host ?? "nil")")
            throw URLError(.unsupportedURL)
        }
        let suiteName = "MusTag.ShazamFlowTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let model = AppModel(fileStore: store, recognition: recognition, coverArt: CoverArtService(session: session),
                             recognitionProvider: provider, preferences: preferences)
        model.apiKey = ""
        await model.load()
        return Context(root: root, source: source, originalBytes: try Data(contentsOf: source), document: document,
                       store: store, session: session, preferences: preferences, suiteName: suiteName, model: model)
    }

    @MainActor
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(8)
        while model.isWorking, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !model.isWorking else {
            model.cancelOperation()
            XCTFail("Shazam operation did not complete before the deadline")
            throw URLError(.timedOut)
        }
    }

    @MainActor
    private func assertOriginalUntouched(_ context: Context, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: context.document.url), context.originalBytes, file: file, line: line)
        let backups = try await context.store.backups()
        XCTAssertTrue(backups.isEmpty, "Recognition must not write a source file or create a backup", file: file, line: line)
    }

    private func artwork(color: UIColor) throws -> AudioArtwork {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return AudioArtwork(data: try XCTUnwrap(image.pngData()), mimeType: "image/png")
    }

    @MainActor
    private struct Context {
        let root: URL
        let source: URL
        let originalBytes: Data
        let document: AudioDocument
        let store: AudioFileStore
        let session: URLSession
        let preferences: UserDefaults
        let suiteName: String
        let model: AppModel

        func cleanUp() {
            model.cancelOperation()
            session.invalidateAndCancel()
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class ShazamFlowURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var data: Data
        var stalls = false
    }
    private static let lock = NSLock()
    private static var responseHandler: ((URLRequest) throws -> Response)?
    private static var recordedRequests: [URLRequest] = []
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    static var handler: ((URLRequest) throws -> Response)? {
        get { lock.lock(); defer { lock.unlock() }; return responseHandler }
        set {
            lock.lock(); defer { lock.unlock() }
            responseHandler = newValue
            recordedRequests = []
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            Self.recordedRequests.append(request)
            Self.lock.unlock()
            let result = try XCTUnwrap(Self.handler)(request)
            if result.stalls { return }
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: result.status,
                                                       httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
