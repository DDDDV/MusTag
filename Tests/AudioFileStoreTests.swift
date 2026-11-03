import Foundation
import XCTest
@testable import MusTag

final class AudioFileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MusTagTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDirectoryImportSkipsUnsupportedAndDoesNotDuplicatePaths() async throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let song = try fixture("track.mp3", directory: album)
        try Data("not audio".utf8).write(to: album.appendingPathComponent("notes.txt"))
        let store = makeStore()
        let result = try await store.importFiles(from: [album, song])
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.documents[0].original.title, "Original")
        XCTAssertFalse(result.documents[0].sourceHash.isEmpty)
    }

    func testCoverOnlyDraftPersistsSavesAndRestores() async throws {
        let song = try fixture()
        let original = AudioArtwork(data: Data("original cover".utf8), mimeType: "image/png")
        let replacement = AudioArtwork(data: Data("new cover".utf8), mimeType: "image/jpeg")
        try FixtureCodec().writeArtwork(original, to: song)
        let bytes = try Data(contentsOf: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        XCTAssertEqual(document.originalArtwork, original)
        document.draftArtwork = replacement
        XCTAssertTrue(document.hasChanges)
        try await store.persistDocuments([document])
        let loaded = try await makeStore().loadDocuments()
        XCTAssertEqual(loaded[0].draftArtwork, replacement)
        XCTAssertEqual(try Data(contentsOf: song), bytes, "A persisted draft must not write the audio file")
        let (saved, backup) = try await store.save(loaded[0])
        XCTAssertFalse(saved.hasChanges)
        XCTAssertEqual(saved.originalArtwork, replacement)
        XCTAssertEqual(try FixtureCodec().read(from: song).artwork, replacement)
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), bytes)
        let restored = try await store.restore(backup)
        XCTAssertEqual(restored.draftArtwork, original)
        XCTAssertFalse(restored.hasChanges)
        XCTAssertEqual(try Data(contentsOf: song), bytes)
    }

    func testFailedCoverVerificationLeavesOriginalAndJournalUntouched() async throws {
        let song = try fixture()
        let bytes = try Data(contentsOf: song)
        let store = makeStore(codec: FixtureCodec(ignoreArtwork: true))
        var document = try await firstDocument(song, store: store)
        document.draftArtwork = AudioArtwork(data: Data("cover".utf8), mimeType: "image/png")
        do {
            _ = try await store.save(document)
            XCTFail("A writer dropping the requested cover must be rejected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), bytes)
        let backups = try await store.backups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testTextEditCannotSilentlyDropExistingCover() async throws {
        let song = try fixture()
        try FixtureCodec().writeArtwork(AudioArtwork(data: Data("cover".utf8), mimeType: "image/png"), to: song)
        let bytes = try Data(contentsOf: song)
        let store = makeStore(codec: FixtureCodec(dropArtworkOnTagWrite: true))
        var document = try await firstDocument(song, store: store)
        document.draft.title = "New title"
        do {
            _ = try await store.save(document)
            XCTFail("Text edits must preserve existing cover data")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), bytes)
    }

    func testLegacyLibraryLoadsEmbeddedArtworkWithoutLosingTextDraft() async throws {
        let song = try fixture()
        let artwork = AudioArtwork(data: Data("cover".utf8), mimeType: "image/png")
        try FixtureCodec().writeArtwork(artwork, to: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Pending text"
        document.originalArtwork = nil
        document.draftArtwork = nil
        document.artworkVersion = nil
        try await store.persistDocuments([document])
        let loaded = try await makeStore().loadDocuments()
        XCTAssertEqual(loaded[0].originalArtwork, artwork)
        XCTAssertEqual(loaded[0].draftArtwork, artwork)
        XCTAssertEqual(loaded[0].draft.title, "Pending text")
        XCTAssertFalse(loaded[0].hasArtworkChanges)
    }

    func testDelayedLegacyMigrationKeepsDownloadedCoverDraft() async throws {
        let song = try fixture()
        let original = AudioArtwork(data: Data("original".utf8), mimeType: "image/png")
        let downloaded = AudioArtwork(data: Data("downloaded".utf8), mimeType: "image/jpeg")
        try FixtureCodec().writeArtwork(original, to: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.originalArtwork = nil
        document.draftArtwork = downloaded
        document.artworkVersion = nil
        try await store.persistDocuments([document])
        let loaded = try await makeStore().loadDocuments()
        XCTAssertEqual(loaded[0].originalArtwork, original)
        XCTAssertEqual(loaded[0].draftArtwork, downloaded)
    }

    func testSavePreservesAudioAndBackupThenUndoRestoresExactOriginal() async throws {
        let song = try fixture()
        let originalBytes = try Data(contentsOf: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Corrected"
        document.draft.albumArtist = "Various Artists"
        let (saved, backup) = try await store.save(document)

        XCTAssertFalse(saved.hasChanges)
        XCTAssertEqual(saved.original.title, "Corrected")
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.albumArtist, "Various Artists")
        XCTAssertEqual(try FixtureCodec.payload(song), "audio samples remain identical")
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), originalBytes)
        let records = try await store.backups()
        XCTAssertEqual(records.count, 1)
        let loaded = try await store.loadDocuments()
        XCTAssertEqual(loaded.first?.sourceHash, saved.sourceHash)

        let restored = try await store.restore(backup)
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)
        XCTAssertEqual(restored.original.title, "Original")
        let afterRestore = try await store.backups()
        XCTAssertTrue(afterRestore[0].restored)
    }

    func testSaveRefusesToOverwriteExternalChanges() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "My change"
        var external = document.original
        external.title = "Changed by another app"
        try FixtureCodec().write(external, to: song)
        let externalBytes = try Data(contentsOf: song)

        do {
            _ = try await store.save(document)
            XCTFail("Stale imports must not overwrite newer source files")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), externalBytes)
        let records = try await store.backups()
        XCTAssertTrue(records.isEmpty)
    }

    func testFailedPayloadVerificationNeverTouchesOriginal() async throws {
        let song = try fixture()
        let before = try Data(contentsOf: song)
        let store = makeStore(codec: FixtureCodec(corruptAudio: true))
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Requested edit"

        do {
            _ = try await store.save(document)
            XCTFail("A writer changing the audio payload must be rejected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), before)
        let records = try await store.backups()
        XCTAssertTrue(records.isEmpty)
        let backups = root.appendingPathComponent("State/Backups")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testFailedTagRoundTripNeverTouchesOriginal() async throws {
        let song = try fixture()
        let before = try Data(contentsOf: song)
        let store = makeStore(codec: FixtureCodec(ignoreTags: true))
        var document = try await firstDocument(song, store: store)
        document.draft.genre = "Jazz"
        do {
            _ = try await store.save(document)
            XCTFail("Dropped tags must be caught before replacing the source")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), before)
    }

    func testUndoRefusesToClobberExternalChanges() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "First edit"
        let (saved, backup) = try await store.save(document)
        var external = saved.original
        external.title = "New external edit"
        try FixtureCodec().write(external, to: song)
        let beforeUndo = try Data(contentsOf: song)
        do {
            _ = try await store.restore(backup)
            XCTFail("Undo must not overwrite a file edited elsewhere")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), beforeUndo)
        let records = try await store.backups()
        XCTAssertFalse(records[0].restored)
    }

    func testUndoRequiresNewestVersionFirst() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "First edit"
        let (first, firstBackup) = try await store.save(document)
        var secondEdit = first
        secondEdit.draft.title = "Second edit"
        let (_, secondBackup) = try await store.save(secondEdit)
        do {
            _ = try await store.restore(firstBackup)
            XCTFail("Older undo must not jump across newer edits")
        } catch { }
        _ = try await store.restore(secondBackup)
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.title, "First edit")
        _ = try await store.restore(firstBackup)
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.title, "Original")
    }

    func testTamperedBackupIsNeverRestored() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Saved edit"
        let (_, backup) = try await store.save(document)
        let beforeUndo = try Data(contentsOf: song)
        try Data("damaged backup".utf8).write(to: backup.backupURL)
        do {
            _ = try await store.restore(backup)
            XCTFail("Corrupt backups must fail hash verification")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), beforeUndo)
    }

    func testDraftAndUndoJournalSurviveNewStoreInstance() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.album = "Album draft"
        try await store.persistDocuments([document])
        let relaunched = makeStore()
        let loaded = try await relaunched.loadDocuments()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].draft.album, "Album draft")
        XCTAssertEqual(loaded[0].original.album, "")
        let (_, backup) = try await relaunched.save(loaded[0])
        let anotherLaunch = makeStore()
        let records = try await anotherLaunch.backups()
        XCTAssertEqual(records.first?.id, backup.id)
        _ = try await anotherLaunch.restore(records[0])
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.album, "")
    }

    func testMalformedJournalBlocksSavingInsteadOfDiscardingBackups() async throws {
        let song = try fixture()
        let before = try Data(contentsOf: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Edit"
        try Data("invalid json".utf8).write(to: root.appendingPathComponent("State/backups.json"))
        do {
            _ = try await store.save(document)
            XCTFail("A damaged undo journal must not be silently replaced")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), before)
    }

    func testBackupSurvivesRelocatedApplicationStorage() async throws {
        let song = try fixture()
        let before = try Data(contentsOf: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Saved edit"
        _ = try await store.save(document)
        let movedState = root.appendingPathComponent("RelocatedState")
        try FileManager.default.moveItem(at: root.appendingPathComponent("State"), to: movedState)
        let relaunched = AudioFileStore(codec: FixtureCodec(), storageDirectory: movedState,
                                       payloadHasher: { try FixtureCodec.payload($0) })
        let backups = try await relaunched.backups()
        XCTAssertTrue(backups[0].backupURL.path.hasPrefix(movedState.path))
        _ = try await relaunched.restore(backups[0])
        XCTAssertEqual(try Data(contentsOf: song), before)
    }

    func testCancelledImportKeepsCompletedDocuments() async throws {
        let first = try fixture("first.mp3")
        let second = try fixture("second.mp3")
        let store = makeStore(codec: FixtureCodec(cancelOnRead: true))
        let task = Task { try await store.importFiles(from: [first, second]) }
        let result = try await task.value
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].fileName, "first.mp3")
        XCTAssertFalse(result.failures.isEmpty)
    }

    private func makeStore(codec: FixtureCodec = FixtureCodec()) -> AudioFileStore {
        AudioFileStore(codec: codec, storageDirectory: root.appendingPathComponent("State"),
                       payloadHasher: { try FixtureCodec.payload($0) })
    }

    private func firstDocument(_ url: URL, store: AudioFileStore) async throws -> AudioDocument {
        let result = try await store.importFiles(from: [url])
        return try XCTUnwrap(result.documents.first, result.failures.joined(separator: "; "))
    }

    private func fixture(_ name: String = "song.mp3", directory: URL? = nil) throws -> URL {
        let file = (directory ?? root!).appendingPathComponent(name)
        var tags = AudioTags.empty
        tags.title = "Original"
        tags.artist = "Original Artist"
        let data = try JSONEncoder().encode(FixtureAudio(tags: tags, payload: "audio samples remain identical"))
        try data.write(to: file)
        return file
    }
}

private struct FixtureAudio: Codable {
    var tags: AudioTags
    var payload: String
    var artwork: AudioArtwork? = nil
}

private struct FixtureCodec: AudioMetadataCodec {
    var corruptAudio = false
    var ignoreTags = false
    var cancelOnRead = false
    var ignoreArtwork = false
    var dropArtworkOnTagWrite = false

    func read(from url: URL) throws -> AudioSnapshot {
        let file = try JSONDecoder().decode(FixtureAudio.self, from: Data(contentsOf: url))
        if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        return AudioSnapshot(tags: file.tags, duration: 180, artwork: file.artwork)
    }

    func write(_ tags: AudioTags, to url: URL) throws {
        var file = try JSONDecoder().decode(FixtureAudio.self, from: Data(contentsOf: url))
        if !ignoreTags { file.tags = tags }
        if corruptAudio { file.payload = "corrupted audio" }
        if dropArtworkOnTagWrite { file.artwork = nil }
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }

    func writeArtwork(_ artwork: AudioArtwork, to url: URL) throws {
        var file = try JSONDecoder().decode(FixtureAudio.self, from: Data(contentsOf: url))
        if !ignoreArtwork { file.artwork = artwork }
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }

    static func payload(_ url: URL) throws -> String {
        try JSONDecoder().decode(FixtureAudio.self, from: Data(contentsOf: url)).payload
    }
}
