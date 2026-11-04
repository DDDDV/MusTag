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
        XCTAssertNil(candidate.recordingID, "A Shazam ID is not a MusicBrainz recording ID")
        XCTAssertNil(candidate.releaseID)
        XCTAssertEqual(context.model.appliedCandidateIDs[document.id], candidate.id)
        XCTAssertFalse(context.model.showsSettings)
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
            XCTAssertEqual(request.url, expectedURL, "Shazam artwork must not route through MusicBrainz or CAA")
            return .init(status: 200, data: downloaded.data)
        }

        context.model.identify([context.document.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let document = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(document.draft.title, match.title)
        XCTAssertEqual(document.draft.artist, match.artist)
        XCTAssertEqual(document.draft.genre, "Pop")
        XCTAssertEqual(document.draftArtwork, downloaded)
        XCTAssertNil(document.error)
        let candidate = try XCTUnwrap(context.model.candidates[document.id]?.first)
        XCTAssertEqual(candidate.appleMusicURL, appleMusicURL)
        XCTAssertEqual(candidate.isrc, match.isrc)
        XCTAssertNil(candidate.score)
        let attribution = ShazamAttribution(title: match.title, artist: match.artist, appleMusicURL: appleMusicURL)
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
            ShazamFlowURLProtocol.handler = { _ in .init(status: status, data: Data()) }

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
        ShazamFlowURLProtocol.handler = { _ in
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
        let previousAttribution = ShazamAttribution(title: "Original title", artist: "Original artist",
            appleMusicURL: URL(string: "https://music.apple.com/us/song/original/100"))
        let match = ShazamRecognitionResult(id: "110", title: "Saved recognition", artist: "Matched artist",
                                           artworkURL: artworkURL,
                                           appleMusicURL: URL(string: "https://music.apple.com/us/song/new/110"))
        let expectedAttribution = ShazamAttribution(title: match.title, artist: match.artist,
                                                    appleMusicURL: match.appleMusicURL)
        let context = try await context(matches: [match], originalAttribution: previousAttribution)
        defer { context.cleanUp() }
        let downloaded = try artwork(color: .blue)
        ShazamFlowURLProtocol.handler = { _ in .init(status: 200, data: downloaded.data) }
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
        let snapshot = try NativeMetadataCodec().read(from: context.source)
        XCTAssertEqual(snapshot.tags.title, match.title)
        XCTAssertEqual(snapshot.tags.album, context.document.original.album)
        XCTAssertEqual(snapshot.artwork, downloaded)
        XCTAssertEqual(try NativeAudio.payloadHash(url: context.source), originalAudioHash)
        let backups = try await context.store.backups()
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), context.originalBytes)
        XCTAssertEqual(backup.originalShazamAttribution, previousAttribution)
        let reopened = AppModel(fileStore: context.store, preferences: context.preferences)
        await reopened.load()
        XCTAssertEqual(reopened.document(saved.id)?.originalShazamAttribution, expectedAttribution)

        context.model.restore(backup)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        XCTAssertEqual(context.model.document(context.document.id)?.original, context.document.original)
        XCTAssertEqual(context.model.document(context.document.id)?.originalArtwork, context.document.originalArtwork)
        XCTAssertEqual(context.model.document(context.document.id)?.originalShazamAttribution, previousAttribution)
        XCTAssertEqual(context.model.document(context.document.id)?.draftShazamAttribution, previousAttribution)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first?.originalShazamAttribution, previousAttribution)
    }

    @MainActor
    private func context(matches: [ShazamRecognitionResult], provider: RecognitionProvider? = nil,
                         shazamProvider: MusicRecognitionService.ShazamProvider? = nil,
                         originalAttribution: ShazamAttribution? = nil) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShazamFlow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.m4a")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "m4a", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: source)
        let codec = NativeMetadataCodec()
        try codec.write(AudioTags(title: "Original title", artist: "Original artist", album: "Original album",
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
        let recognition = MusicRecognitionService(session: session, minimumMusicBrainzInterval: 0,
            minimumAcoustIDInterval: 0, fingerprintProvider: { _ in
                XCTFail("Selecting Shazam must not run AcoustID fingerprinting")
                throw URLError(.unsupportedURL)
            }, shazamProvider: recognize)
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
    static var handler: ((URLRequest) throws -> Response)? {
        get { lock.lock(); defer { lock.unlock() }; return responseHandler }
        set { lock.lock(); defer { lock.unlock() }; responseHandler = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
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
