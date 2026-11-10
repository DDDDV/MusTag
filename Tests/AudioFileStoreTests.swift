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
        XCTAssertEqual(result.folders.first?.sourceURL, album.standardizedFileURL)
        XCTAssertNotEqual(result.folders.first?.url, album.standardizedFileURL)
        XCTAssertEqual(result.documents[0].url.deletingLastPathComponent(), result.folders[0].url)
        XCTAssertEqual(result.documents[0].importFolderIDs, Set([result.folders[0].id]))
    }

    func testIndividualFileImportDoesNotInferParentFolder() async throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let song = try fixture(directory: album)
        let result = try await makeStore().importFiles(from: [song])
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertNil(result.documents[0].importFolderIDs)
    }

    func testMixedNestedAndSameNamedFoldersKeepDistinctOriginsWithoutDuplicateFiles() async throws {
        let firstAlbum = root.appendingPathComponent("First/Album", isDirectory: true)
        let disc = firstAlbum.appendingPathComponent("Disc 1", isDirectory: true)
        let otherAlbum = root.appendingPathComponent("Second/Album", isDirectory: true)
        for directory in [disc, otherAlbum] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let firstSong = try fixture("track.mp3", directory: firstAlbum)
        let nestedSong = try fixture("track.flac", directory: disc)
        let otherSong = try fixture("track.mp3", directory: otherAlbum)
        let looseSong = try fixture("loose.m4a")
        let result = try await makeStore().importFiles(from: [nestedSong, firstAlbum, disc, otherAlbum, firstAlbum, looseSong])

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.documents.count, 4)
        XCTAssertEqual(result.folders.count, 3)
        let firstID = AudioFolder(url: firstAlbum).id
        let discID = AudioFolder(url: disc).id
        let otherID = AudioFolder(url: otherAlbum).id
        XCTAssertNotEqual(firstID, otherID, "Folders with the same name must stay separate")
        let imported = Dictionary(uniqueKeysWithValues: result.documents.map { ($0.sourceURL!.standardizedFileURL, $0) })
        XCTAssertEqual(imported[firstSong.standardizedFileURL]?.importFolderIDs, Set([firstID]))
        XCTAssertEqual(imported[nestedSong.standardizedFileURL]?.importFolderIDs, Set([firstID, discID]))
        XCTAssertEqual(imported[otherSong.standardizedFileURL]?.importFolderIDs, Set([otherID]))
        XCTAssertNil(imported[looseSong.standardizedFileURL]?.importFolderIDs)
    }

    func testEmptyFolderImportPersistsWithoutAudioDocuments() async throws {
        let folder = root.appendingPathComponent("Empty Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let store = makeStore()
        let result = try await store.importFiles(from: [folder, folder])
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.folders.count, 1)
        try await store.persistLibrary(AudioLibrary(documents: result.documents, folders: result.folders))

        let loaded = try await makeStore().loadLibrary()
        XCTAssertTrue(loaded.documents.isEmpty)
        XCTAssertEqual(loaded.folders, result.folders)
    }

    func testFolderMembershipAndDraftSurviveRelaunchSaveAndRestore() async throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        for folder in [album, empty] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let song = try fixture(directory: album)
        let originalBytes = try Data(contentsOf: song)
        let store = makeStore()
        let result = try await store.importFiles(from: [album, empty])
        var document = try XCTUnwrap(result.documents.first)
        document.draft.title = "Folder draft"
        let memberships = document.importFolderIDs
        try await store.persistLibrary(AudioLibrary(documents: [document], folders: result.folders))

        let relaunched = makeStore()
        var loaded = try await relaunched.loadLibrary()
        XCTAssertEqual(loaded.folders, result.folders)
        XCTAssertEqual(loaded.documents[0].importFolderIDs, memberships)
        XCTAssertEqual(loaded.documents[0].draft.title, "Folder draft")
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)
        // Existing callers that update only documents must retain folder records too.
        try await relaunched.persistDocuments(loaded.documents)
        let (saved, backup) = try await relaunched.save(loaded.documents[0])
        XCTAssertEqual(saved.importFolderIDs, memberships)
        loaded = try await makeStore().loadLibrary()
        XCTAssertEqual(loaded.folders, result.folders)
        XCTAssertEqual(loaded.documents[0].importFolderIDs, memberships)
        XCTAssertFalse(loaded.documents[0].hasChanges)

        let restored = try await makeStore().restore(backup)
        XCTAssertEqual(restored.importFolderIDs, memberships)
        loaded = try await makeStore().loadLibrary()
        XCTAssertEqual(loaded.folders, result.folders)
        XCTAssertEqual(loaded.documents[0].importFolderIDs, memberships)
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)
    }

    func testLegacyDocumentArrayLoadsAndMigratesWithoutInventingFolderOrigins() async throws {
        let song = try fixture()
        var document = try await firstDocument(song, store: makeStore())
        document.draft.title = "Legacy draft"
        document.url = song
        document.bookmark = nil
        document.sourceURL = nil
        document.libraryRelativePath = nil
        let indexURL = root.appendingPathComponent("State/documents.json")
        try JSONEncoder().encode([document]).write(to: indexURL)

        let store = makeStore()
        let loaded = try await store.loadLibrary()
        XCTAssertTrue(loaded.folders.isEmpty)
        XCTAssertEqual(loaded.documents.count, 1)
        XCTAssertEqual(loaded.documents[0].id, document.id)
        XCTAssertEqual(loaded.documents[0].draft.title, "Legacy draft")
        XCTAssertNil(loaded.documents[0].importFolderIDs)
        XCTAssertNotEqual(loaded.documents[0].url, song)
        XCTAssertEqual(loaded.documents[0].sourceURL, song)
        XCTAssertNotNil(loaded.documents[0].libraryRelativePath)
        try await store.persistLibrary(loaded)
        let migrated = try JSONDecoder().decode(AudioLibrary.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(migrated.documents[0].id, document.id)
        XCTAssertTrue(migrated.folders.isEmpty)
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
        XCTAssertEqual(try FixtureCodec().read(from: saved.url).artwork, replacement)
        XCTAssertEqual(try Data(contentsOf: song), bytes)
        try assertMetadataBackup(backup)
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
        XCTAssertEqual(try Data(contentsOf: document.url), bytes)
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
        XCTAssertEqual(try Data(contentsOf: document.url), bytes)
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
        XCTAssertEqual(try FixtureCodec().read(from: saved.url).tags.albumArtist, "Various Artists")
        XCTAssertEqual(try Data(contentsOf: song), originalBytes, "Saving must not change the import source")
        XCTAssertEqual(try FixtureCodec.payload(saved.url), "audio samples remain identical")
        try assertMetadataBackup(backup)
        try assertNoTemporaryFiles()
        let records = try await store.backups()
        XCTAssertEqual(records.count, 1)
        let loaded = try await store.loadDocuments()
        XCTAssertEqual(loaded.first?.sourceHash, saved.sourceHash)

        let restored = try await store.restore(backup)
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)
        XCTAssertEqual(restored.original.title, "Original")
        let afterRestore = try await store.backups()
        XCTAssertTrue(afterRestore[0].restored)
        try assertNoTemporaryFiles()
    }

    func testSaveRefusesToOverwriteLocalCopyChangedByAnotherApp() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "My change"
        var external = document.original
        external.title = "Changed by another app"
        try FixtureCodec().write(external, to: document.url)
        let externalBytes = try Data(contentsOf: document.url)

        do {
            _ = try await store.save(document)
            XCTFail("Stale imports must not overwrite newer source files")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: document.url), externalBytes)
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
        XCTAssertEqual(try Data(contentsOf: document.url), before)
        let records = try await store.backups()
        XCTAssertTrue(records.isEmpty)
        let backups = root.appendingPathComponent("State/Backups")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        try assertNoTemporaryFiles()
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
        XCTAssertEqual(try Data(contentsOf: document.url), before)
    }

    func testUndoRefusesToClobberLocalCopyChangedByAnotherApp() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "First edit"
        let (saved, backup) = try await store.save(document)
        var external = saved.original
        external.title = "New external edit"
        try FixtureCodec().write(external, to: saved.url)
        let beforeUndo = try Data(contentsOf: saved.url)
        do {
            _ = try await store.restore(backup)
            XCTFail("Undo must not overwrite a file edited elsewhere")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: saved.url), beforeUndo)
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
        XCTAssertEqual(try FixtureCodec().read(from: document.url).tags.title, "First edit")
        _ = try await store.restore(firstBackup)
        XCTAssertEqual(try FixtureCodec().read(from: document.url).tags.title, "Original")
    }

    func testTamperedBackupIsNeverRestored() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Saved edit"
        let (_, backup) = try await store.save(document)
        let beforeUndo = try Data(contentsOf: document.url)
        try Data("damaged backup".utf8).write(to: backup.backupURL)
        do {
            _ = try await store.restore(backup)
            XCTFail("Corrupt backups must fail hash verification")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: document.url), beforeUndo)
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
        XCTAssertEqual(try Data(contentsOf: document.url), before)
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
                                       payloadHasher: { try FixtureCodec.payload($0) },
                                       payloadRanges: { try FixtureCodec.payloadRanges($0) })
        let backups = try await relaunched.backups()
        XCTAssertTrue(backups[0].backupURL.path.hasPrefix(movedState.path))
        let restored = try await relaunched.restore(backups[0])
        XCTAssertTrue(restored.url.path.hasPrefix(movedState.path))
        XCTAssertEqual(try Data(contentsOf: restored.url), before)
        let loaded = try await relaunched.loadDocuments()
        XCTAssertEqual(loaded.first?.url, restored.url)
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

    func testMetadataBackupSizeDoesNotGrowWithAudioPayload() async throws {
        let store = makeStore()
        var backupSizes: [Int] = []
        for size in [4_096, 1_048_576] {
            let song = root.appendingPathComponent("audio-\(size).mp3")
            let payload = String(repeating: "A", count: size)
            var tags = AudioTags.empty
            tags.title = "Original"
            let original = try JSONEncoder().encode(FixtureAudio(tags: tags, payload: payload))
            try original.write(to: song)
            var document = try await firstDocument(song, store: store)
            document.draft.title = "Changed"
            let (_, backup) = try await store.save(document)
            let data = try Data(contentsOf: backup.backupURL)
            backupSizes.append(data.count)
            XCTAssertNil(data.range(of: Data(repeating: 65, count: 1_024)), "Audio must not be embedded in the metadata backup")
            XCTAssertLessThan(data.count, 2_048)
            _ = try await store.restore(backup)
            XCTAssertEqual(try Data(contentsOf: song), original)
        }
        XCTAssertLessThan(abs(backupSizes[1] - backupSizes[0]), 64,
                          "Only the encoded audio-length bookkeeping may change")
    }

    func testLegacyFullFileBackupRestoresAfterUndoingNewMetadataBackup() async throws {
        let song = try fixture()
        let original = try Data(contentsOf: song)
        let originalHash = try AudioFileStore.fileHash(song)
        let originalTags = try FixtureCodec().read(from: song).tags
        let store = makeStore()
        _ = try await store.loadLibrary()
        let backupURL = root.appendingPathComponent("State/Backups/legacy.mp3")
        try original.write(to: backupURL)
        var tags = originalTags
        tags.title = "Saved by an older version"
        try FixtureCodec().write(tags, to: song)
        let legacyEdited = try Data(contentsOf: song)
        let document = AudioDocument(url: song, bookmark: nil, original: tags, draft: tags,
                                     duration: 180, error: nil, sourceHash: try AudioFileStore.fileHash(song))
        try await store.persistDocuments([document])
        let legacy = BackupRecord(documentID: document.id, originalURL: song, bookmark: nil,
                                  backupURL: backupURL, originalHash: originalHash,
                                  writtenHash: document.sourceHash)
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([legacy])) as? [[String: Any]])
        records[0].removeValue(forKey: "backupHash")
        try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("State/backups.json"))

        let relaunched = makeStore()
        let library = try await relaunched.loadLibrary()
        var nextEdit = try XCTUnwrap(library.documents.first)
        XCTAssertNotEqual(nextEdit.url, song)
        XCTAssertEqual(nextEdit.id, document.id)
        let loaded = try await relaunched.backups()
        let backup = try XCTUnwrap(loaded.first)
        XCTAssertNil(backup.backupHash)
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), original)
        nextEdit.draft.title = "Saved by the new version"
        let (_, metadataBackup) = try await relaunched.save(nextEdit)
        XCTAssertNotNil(metadataBackup.backupHash)
        do {
            _ = try await relaunched.restore(backup)
            XCTFail("The legacy restore must still require newer saves to be undone first")
        } catch { }
        _ = try await relaunched.restore(metadataBackup)
        XCTAssertEqual(try Data(contentsOf: nextEdit.url), legacyEdited)
        let restored = try await relaunched.restore(backup)
        XCTAssertEqual(restored.original, originalTags)
        XCTAssertEqual(try Data(contentsOf: restored.url), original)
        XCTAssertEqual(try Data(contentsOf: song), legacyEdited, "Legacy restore must not write back to the source")
        XCTAssertEqual(try Data(contentsOf: backup.backupURL), original, "Legacy exports remain full audio files")
    }

    func testMetadataBackupCannotRestoreWhenAudioFileIsMissing() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Saved edit"
        let (_, backup) = try await store.save(document)
        try FileManager.default.removeItem(at: document.url)
        do {
            _ = try await store.restore(backup)
            XCTFail("Metadata alone cannot reconstruct a missing audio payload")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.path))
        let records = try await store.backups()
        XCTAssertFalse(records[0].restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.backupURL.path))
    }

    func testImportedSourceCanChangeWithoutChangingOrBlockingLocalSave() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        XCTAssertNotEqual(document.url, song)
        XCTAssertTrue(document.url.path.hasPrefix(store.libraryDirectory.path + "/"))
        XCTAssertEqual(document.sourceURL, song)
        var external = document.original
        external.title = "Changed at source"
        try FixtureCodec().write(external, to: song)
        let sourceBytes = try Data(contentsOf: song)
        document.draft.title = "Edited locally"
        let (saved, backup) = try await store.save(document)
        XCTAssertEqual(try FixtureCodec().read(from: saved.url).tags.title, "Edited locally")
        XCTAssertEqual(try Data(contentsOf: song), sourceBytes)
        let restored = try await store.restore(backup)
        XCTAssertEqual(restored.original.title, "Original")
        XCTAssertEqual(try Data(contentsOf: song), sourceBytes)
    }

    func testReimportAfterRemovingIndexKeepsEditedCopyInsteadOfOverwritingIt() async throws {
        let song = try fixture()
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "Keep my edit"
        let (saved, _) = try await store.save(document)
        let savedBytes = try Data(contentsOf: saved.url)
        var external = document.original
        external.title = "New source version"
        try FixtureCodec().write(external, to: song)
        try await store.persistDocuments([])

        let reimported = try await firstDocument(song, store: makeStore())
        XCTAssertEqual(reimported.url, saved.url)
        XCTAssertEqual(reimported.original.title, "Keep my edit")
        XCTAssertEqual(try Data(contentsOf: reimported.url), savedBytes)
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.title, "New source version")
    }

    func testDownloadedFileAlreadyInLibraryIsImportedWithoutAnotherCopy() async throws {
        let store = makeStore()
        let downloads = store.libraryDirectory.appendingPathComponent("Downloads/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let song = try fixture(directory: downloads)
        var document = try await firstDocument(song, store: store)
        XCTAssertEqual(document.url, song)
        XCTAssertEqual(document.libraryRelativePath, "Downloads/Album/song.mp3")
        document.draft.title = "Local download edit"
        let (saved, _) = try await store.save(document)
        XCTAssertEqual(saved.url, song)
        XCTAssertEqual(try FixtureCodec().read(from: song).tags.title, "Local download edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.libraryDirectory.appendingPathComponent("Imported Files").path))
    }

    func testLegacyExternalLibraryMigratesIDsDraftsAndFolderTreeBeforeSaving() async throws {
        let album = root.appendingPathComponent("Old Album", isDirectory: true)
        let disc = album.appendingPathComponent("Disc 2", isDirectory: true)
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        let source = try fixture(directory: disc)
        let sourceBytes = try Data(contentsOf: source)
        let snapshot = try FixtureCodec().read(from: source)
        let folder = AudioFolder(url: album)
        var old = AudioDocument(url: source, bookmark: nil, original: snapshot.tags, draft: snapshot.tags,
                                duration: snapshot.duration, error: nil, sourceHash: try AudioFileStore.fileHash(source),
                                importFolderIDs: [folder.id])
        old.draft.title = "Pending legacy draft"
        let store = makeStore()
        try await store.persistLibrary(AudioLibrary(documents: [old], folders: [folder]))

        let library = try await makeStore().loadLibrary()
        let local = try XCTUnwrap(library.documents.first)
        let localFolder = try XCTUnwrap(library.folders.first)
        XCTAssertEqual(local.id, old.id)
        XCTAssertEqual(local.draft, old.draft)
        XCTAssertEqual(local.importFolderIDs, old.importFolderIDs)
        XCTAssertEqual(localFolder.id, folder.id)
        XCTAssertEqual(local.url, localFolder.url.appendingPathComponent("Disc 2/song.mp3"))
        XCTAssertEqual(local.sourceURL, source)
        XCTAssertNil(local.error)
        _ = try await store.save(local)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        let loadedAgain = try await makeStore().loadLibrary()
        XCTAssertEqual(loadedAgain.documents.first?.url, local.url)
        XCTAssertEqual(loadedAgain.documents.first?.original.title, "Pending legacy draft")
    }

    func testSaveRejectsExternalRemoteAndEscapingRelativeURLs() async throws {
        let song = try fixture()
        let sourceBytes = try Data(contentsOf: song)
        let store = makeStore()
        let original = try await firstDocument(song, store: store)
        for target in [song, URL(string: "https://example.invalid/song.mp3")!,
                       store.libraryDirectory.appendingPathComponent("../outside.mp3")] {
            var forged = original
            forged.url = target
            forged.bookmark = nil
            forged.libraryRelativePath = nil
            forged.draft.title = "Must not save"
            do {
                _ = try await store.save(forged)
                XCTFail("Saving outside the owned library must fail")
            } catch { }
        }
        var escaped = original
        escaped.libraryRelativePath = "../song.mp3"
        escaped.draft.title = "Must not save"
        do {
            _ = try await store.save(escaped)
            XCTFail("Relative paths cannot escape the library")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: original.url), sourceBytes)
        let backups = try await store.backups()
        XCTAssertTrue(backups.isEmpty)
    }

    func testSaveAndRestoreRejectLibraryDirectoryReplacedBySymlink() async throws {
        let song = try fixture()
        let sourceBytes = try Data(contentsOf: song)
        let store = makeStore()
        var document = try await firstDocument(song, store: store)
        document.draft.title = "First save"
        let (saved, backup) = try await store.save(document)
        let localParent = saved.url.deletingLastPathComponent()
        let outside = root.appendingPathComponent("Outside Library", isDirectory: true)
        try FileManager.default.moveItem(at: localParent, to: outside)
        try FileManager.default.createSymbolicLink(at: localParent, withDestinationURL: outside)
        let outsideFile = outside.appendingPathComponent(saved.fileName)
        let outsideBytes = try Data(contentsOf: outsideFile)
        var next = saved
        next.draft.title = "Must not write through link"
        do {
            _ = try await store.save(next)
            XCTFail("Save must reject a symlink in the local path")
        } catch { }
        do {
            _ = try await store.restore(backup)
            XCTFail("Restore must reject a symlink in the local path")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: outsideFile), outsideBytes)
        XCTAssertEqual(try Data(contentsOf: song), sourceBytes)
    }

    func testUnmigratedLegacyBackupCannotRestoreToExternalSource() async throws {
        let song = try fixture()
        let before = try Data(contentsOf: song)
        let store = makeStore()
        _ = try await store.loadLibrary()
        let backupURL = root.appendingPathComponent("State/Backups/legacy.mp3")
        try before.write(to: backupURL)
        let hash = try AudioFileStore.fileHash(song)
        let record = BackupRecord(documentID: UUID(), originalURL: song, bookmark: nil,
                                  backupURL: backupURL, originalHash: hash, writtenHash: hash)
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("State/backups.json"))
        do {
            _ = try await store.restore(record)
            XCTFail("A legacy backup must first be associated with an imported local file")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: song), before)
        let backups = try await store.backups()
        XCTAssertFalse(backups[0].restored)
    }

    func testMissingLegacySourceRetriesMigrationWithoutLosingDraft() async throws {
        let source = try fixture()
        let bytes = try Data(contentsOf: source)
        let snapshot = try FixtureCodec().read(from: source)
        var old = AudioDocument(url: source, bookmark: nil, original: snapshot.tags, draft: snapshot.tags,
                                duration: snapshot.duration, error: nil, sourceHash: try AudioFileStore.fileHash(source))
        old.draft.title = "Keep through failed migration"
        try await makeStore().persistDocuments([old])
        try FileManager.default.removeItem(at: source)
        for _ in 0..<2 {
            let loaded = try await makeStore().loadDocuments()
            XCTAssertEqual(loaded[0].id, old.id)
            XCTAssertEqual(loaded[0].url, source)
            XCTAssertNil(loaded[0].libraryRelativePath)
            XCTAssertEqual(loaded[0].draft, old.draft)
            XCTAssertNotNil(loaded[0].error)
        }
        try bytes.write(to: source)
        let loaded = try await makeStore().loadDocuments()
        XCTAssertEqual(loaded[0].id, old.id)
        XCTAssertEqual(loaded[0].draft, old.draft)
        XCTAssertNotEqual(loaded[0].url, source)
        XCTAssertNotNil(loaded[0].libraryRelativePath)
        XCTAssertNil(loaded[0].error)
    }

    func testReimportingRelocatedLocalFolderKeepsFolderAndDocumentIdentities() async throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        _ = try fixture(directory: album)
        let store = makeStore()
        let imported = try await store.importFiles(from: [album])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let moved = root.appendingPathComponent("RelocatedState", isDirectory: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("State"), to: moved)
        let relaunched = AudioFileStore(codec: FixtureCodec(), storageDirectory: moved,
                                       payloadHasher: { try FixtureCodec.payload($0) },
                                       payloadRanges: { try FixtureCodec.payloadRanges($0) })
        let loaded = try await relaunched.loadLibrary()
        let reimported = try await relaunched.importFiles(from: [loaded.folders[0].url])
        XCTAssertTrue(reimported.failures.isEmpty)
        XCTAssertEqual(reimported.folders[0].id, imported.folders[0].id)
        XCTAssertEqual(reimported.documents[0].id, imported.documents[0].id)
        XCTAssertEqual(reimported.documents[0].importFolderIDs, imported.documents[0].importFolderIDs)
        XCTAssertEqual(reimported.documents[0].sourceURL, imported.documents[0].sourceURL)
    }

    func testRelaunchedStoreRejectsSymlinkAboveLibraryRoot() async throws {
        let source = try fixture()
        let library = root.appendingPathComponent("Container/Music", isDirectory: true)
        let store = makeStore(libraryDirectory: library)
        var document = try await firstDocument(source, store: store)
        document.draft.title = "Saved locally"
        let (saved, backup) = try await store.save(document)
        let outsideContainer = root.appendingPathComponent("Outside Container", isDirectory: true)
        try FileManager.default.moveItem(at: library.deletingLastPathComponent(), to: outsideContainer)
        try FileManager.default.createSymbolicLink(at: library.deletingLastPathComponent(), withDestinationURL: outsideContainer)
        let outsideFile = outsideContainer.appendingPathComponent("Music").appendingPathComponent(saved.libraryRelativePath!)
        let bytes = try Data(contentsOf: outsideFile)
        let relaunched = makeStore(libraryDirectory: library)
        var next = saved
        next.draft.title = "Must not save outside"
        do {
            _ = try await relaunched.save(next)
            XCTFail("A new store must not trust a redirected ancestor")
        } catch { }
        do {
            _ = try await relaunched.restore(backup)
            XCTFail("Restoration must reject a redirected ancestor")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: outsideFile), bytes)
    }

    private func assertNoTemporaryFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let staging = root.appendingPathComponent("State/Staging")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty,
                      "Safe-write audio copies must not persist after the operation", file: file, line: line)
    }

    private func assertMetadataBackup(_ backup: BackupRecord, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNotNil(backup.backupHash, file: file, line: line)
        XCTAssertEqual(backup.backupURL.pathExtension, "mustagbackup", file: file, line: line)
        let data = try Data(contentsOf: backup.backupURL)
        XCTAssertNil(data.range(of: Data("audio samples remain identical".utf8)), file: file, line: line)
        _ = try AudioMetadataBackup(data: data)
    }

    private func makeStore(codec: FixtureCodec = FixtureCodec(), libraryDirectory: URL? = nil) -> AudioFileStore {
        AudioFileStore(codec: codec, storageDirectory: root.appendingPathComponent("State"),
                       libraryDirectory: libraryDirectory,
                       payloadHasher: { try FixtureCodec.payload($0) },
                       payloadRanges: { try FixtureCodec.payloadRanges($0) })
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

    static func payloadRanges(_ url: URL) throws -> [AudioPayloadRange] {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(FixtureAudio.self, from: data).payload
        let marker = Data("\"payload\":".utf8)
        let encoded = try JSONEncoder().encode(payload)
        let range = try XCTUnwrap(data.range(of: marker + encoded))
        return [(offset: UInt64(range.lowerBound + marker.count + 1), length: UInt64(encoded.count - 2))]
    }
}
