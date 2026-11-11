import Combine
import Foundation
import XCTest
@testable import MusTag

final class LibraryFlowTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    func testNewLibraryBecomesReadyOnlyAfterInitialLoad() async {
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: root.appendingPathComponent("State"))
        let model = AppModel(fileStore: store)

        XCTAssertEqual(model.libraryLoadState, .loading,
                       "An unread library must not be presented as an empty library")
        await model.load()

        XCTAssertEqual(model.libraryLoadState, .ready)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertNil(model.notice)
    }

    @MainActor
    func testColdStartPublishesReadyAfterRestoringFilesFoldersAndDrafts() async throws {
        let album = try directory("Saved Album")
        _ = try audio("Saved Song", in: album)
        let empty = try directory("Saved Empty Folder")
        let state = root.appendingPathComponent("State")
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
        let imported = try await store.importFiles(from: [album, empty])
        var document = try XCTUnwrap(imported.documents.first)
        document.draft.title = "My unsaved title"
        try await store.persistLibrary(AudioLibrary(documents: [document], folders: imported.folders))
        let originalIndex = try Data(contentsOf: state.appendingPathComponent("documents.json"))
        let model = AppModel(fileStore: store)
        var readyPublications = 0
        let observation = model.$libraryLoadState.sink { loadState in
            guard loadState == .ready else { return }
            readyPublications += 1
            XCTAssertEqual(model.documents.map(\.id), [document.id])
            XCTAssertEqual(model.documents.first?.draft, document.draft)
            XCTAssertEqual(model.folders, imported.folders,
                           "All folder records must be restored before revealing the home page")
        }
        defer { observation.cancel() }

        XCTAssertEqual(model.libraryLoadState, .loading)
        await model.persistNow()
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("documents.json")), originalIndex)
        await model.load()

        XCTAssertEqual(model.libraryLoadState, .ready)
        XCTAssertEqual(readyPublications, 1)
        XCTAssertEqual(model.documents.first?.draft.title, "My unsaved title")
        let emptyFolder = try XCTUnwrap(model.folders.first { $0.name == "Saved Empty Folder" })
        XCTAssertTrue(model.documents(in: emptyFolder).isEmpty)
        await model.load()
        XCTAssertEqual(readyPublications, 1, "Repeated view tasks must not reload an already restored library")
    }

    @MainActor
    func testFailedStartupPreservesUnreadIndexAndCanRetry() async throws {
        let song = try audio("Saved Song", in: root)
        let state = root.appendingPathComponent("State")
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
        let imported = try await store.importFiles(from: [song])
        let document = try XCTUnwrap(imported.documents.first)
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let index = state.appendingPathComponent("documents.json")
        let validIndex = try Data(contentsOf: index)
        let unreadableIndex = Data("{incomplete library".utf8)
        try unreadableIndex.write(to: index, options: .atomic)
        let model = AppModel(fileStore: store)

        await model.load()

        guard case .failed(let message) = model.libraryLoadState else {
            return XCTFail("A failed read must show a retryable error instead of the empty welcome page")
        }
        XCTAssertFalse(message.isEmpty)
        await model.persistNow()
        XCTAssertEqual(try Data(contentsOf: index), unreadableIndex,
                       "Scene persistence after a failed startup must not replace unread user data")

        try validIndex.write(to: index, options: .atomic)
        await model.load()

        XCTAssertEqual(model.libraryLoadState, .ready)
        XCTAssertEqual(model.documents.map(\.id), [document.id])
        XCTAssertNil(model.notice)
    }

    @MainActor
    func testQueuedLocalImportsWaitForSuccessfulStartupRetryAndKeepRestoredDraft() async throws {
        let song = try audio("Saved Song", in: root)
        let state = root.appendingPathComponent("State")
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
        let imported = try await store.importFiles(from: [song])
        var document = try XCTUnwrap(imported.documents.first)
        document.draft.title = "Keep my pending edit"
        try await store.persistLibrary(AudioLibrary(documents: [document], folders: []))
        let index = state.appendingPathComponent("documents.json")
        let validIndex = try Data(contentsOf: index)
        let unreadableIndex = Data("{incomplete library".utf8)
        try unreadableIndex.write(to: index, options: .atomic)
        let downloaded = try audio("Downloaded Song", in: store.libraryDirectory)
        let model = AppModel(fileStore: store)

        model.enqueueLocalImports([downloaded])
        XCTAssertFalse(model.isWorking, "A local download must wait for the existing library to be restored")
        XCTAssertTrue(model.documents.isEmpty)
        await model.load()

        guard case .failed = model.libraryLoadState else {
            return XCTFail("The unreadable library should keep the pending import queued")
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), unreadableIndex)

        try validIndex.write(to: index, options: .atomic)
        await model.load()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.libraryLoadState, .ready)
        XCTAssertNil(model.notice)
        XCTAssertEqual(Set(model.documents.map(\.fileName)), [song.lastPathComponent, downloaded.lastPathComponent])
        XCTAssertEqual(model.document(document.id)?.draft, document.draft)
        let restored = try await store.loadLibrary()
        XCTAssertEqual(Set(restored.documents.map(\.id)), Set(model.documents.map(\.id)))
        XCTAssertEqual(restored.documents.first { $0.id == document.id }?.draft, document.draft)
    }

    @MainActor
    func testUnreadableBackupsDoNotPreventLibraryStartupOrDraftPersistence() async throws {
        let song = try audio("Saved Song", in: root)
        let state = root.appendingPathComponent("State")
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
        let imported = try await store.importFiles(from: [song])
        let document = try XCTUnwrap(imported.documents.first)
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let journal = state.appendingPathComponent("backups.json")
        let unreadableJournal = Data("{incomplete backup journal".utf8)
        try unreadableJournal.write(to: journal, options: .atomic)
        let model = AppModel(fileStore: store)

        await model.load()

        XCTAssertEqual(model.libraryLoadState, .ready)
        XCTAssertEqual(model.documents.map(\.id), [document.id])
        XCTAssertNotNil(model.notice)
        var draft = document.draft
        draft.title = "Keep this edit despite the backup warning"
        model.updateDraft(draft, for: document.id)
        await flushScheduledPersistence(model)

        let restored = try await store.loadLibrary()
        XCTAssertEqual(restored.documents.first?.draft, draft)
        XCTAssertEqual(try Data(contentsOf: journal), unreadableJournal,
                       "A failed backup read must leave the backup index available for recovery")
    }

    @MainActor
    func test600DownloadedFilesPublishOnceAndKeepMainActorResponsiveOnImportAndRefresh() async throws {
        let state = root.appendingPathComponent("State")
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
        let downloaded = store.libraryDirectory.appendingPathComponent("Connections/Server", isDirectory: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        for index in 0..<600 { _ = try audio("Track-\(index)", in: downloaded) }
        let model = AppModel(fileStore: store)
        await model.load()
        var publications = 0
        let observation = model.$documents.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        var originalIDs: Set<UUID> = []
        var editedID: UUID?
        for pass in 0..<2 {
            publications = 0
            let start = ProcessInfo.processInfo.systemUptime
            var lastTick = start
            var longestGap = 0.0
            var ticks = 0
            // Same entry point used by the local-files-added download notification.
            model.enqueueLocalImports([downloaded])
            while model.isWorking, ProcessInfo.processInfo.systemUptime - start < 60 {
                try await Task.sleep(for: .milliseconds(10))
                let now = ProcessInfo.processInfo.systemUptime
                longestGap = max(longestGap, now - lastTick)
                lastTick = now
                ticks += 1
            }
            print("600-file model import pass \(pass + 1): \(ProcessInfo.processInfo.systemUptime - start)s; maximum main-actor heartbeat gap \(longestGap * 1_000)ms; \(publications) document publications")
            XCTAssertFalse(model.isWorking)
            XCTAssertEqual(model.documents.count, 600)
            XCTAssertEqual(publications, 1, "A batch must publish its library once, not once per file")
            XCTAssertGreaterThan(ticks, 1)
            XCTAssertLessThan(longestGap, 0.25, "Bulk import must keep the main actor available for interaction")
            if pass == 0 {
                XCTAssertNil(model.notice)
                originalIDs = Set(model.documents.map(\.id))
                let document = try XCTUnwrap(model.documents.first)
                editedID = document.id
                var draft = document.draft
                draft.title = "Keep my draft through a 600-file refresh"
                model.updateDraft(draft, for: document.id)
            } else {
                XCTAssertEqual(Set(model.documents.map(\.id)), originalIDs)
                XCTAssertEqual(model.document(try XCTUnwrap(editedID))?.draft.title,
                               "Keep my draft through a 600-file refresh")
            }
        }
        let reloaded = await loadedModel()
        XCTAssertEqual(Set(reloaded.documents.map(\.id)), originalIDs)
        XCTAssertEqual(reloaded.document(try XCTUnwrap(editedID))?.draft.title,
                       "Keep my draft through a 600-file refresh")
    }

    func testImportMergeUsesEarliestMatchAndReplacesStaleAliasesWithinBatch() {
        func document(_ name: String, source: URL? = nil) -> AudioDocument {
            AudioDocument(url: root.appendingPathComponent(name), bookmark: nil,
                          original: .empty, draft: .empty, duration: 1, error: nil, sourceURL: source)
        }
        let source = root.appendingPathComponent("external.mp3")
        let first = document("old.mp3", source: source)
        let second = document("second.mp3")
        var incoming = document("moved.mp3", source: source)
        incoming.id = second.id
        let reusedOldPath = document("old.mp3")
        var latest = document("moved.mp3")
        latest.original.title = "Newest metadata"
        latest.draft = latest.original

        let merged = LibraryImportMerge(ImportResult(documents: [incoming, reusedOldPath, latest], failures: []),
                                        into: AudioLibrary(documents: [first, second], folders: []))

        XCTAssertEqual(merged.library.documents.map(\.id), [first.id, second.id, reusedOldPath.id])
        XCTAssertEqual(merged.library.documents[0].original.title, "Newest metadata")
        XCTAssertEqual(merged.library.documents[0].url, latest.url)
        XCTAssertEqual(merged.library.documents[1].url, second.url)
        XCTAssertEqual(merged.refreshedIDs, [first.id])
    }

    func testImportMergeRetainsOtherDocumentsSharingAnOldAlias() {
        let url = root.appendingPathComponent("shared.mp3")
        let first = AudioDocument(url: url, bookmark: nil, original: .empty, draft: .empty, duration: 1, error: nil)
        var second = first
        second.id = UUID()
        var moved = first
        moved.url = root.appendingPathComponent("moved.mp3")
        var refreshedSecond = second
        refreshedSecond.id = UUID()
        refreshedSecond.original.artist = "Refreshed second file"
        refreshedSecond.draft = refreshedSecond.original

        let merged = LibraryImportMerge(ImportResult(documents: [moved, refreshedSecond], failures: []),
                                        into: AudioLibrary(documents: [first, second], folders: []))

        XCTAssertEqual(merged.library.documents.map(\.id), [first.id, second.id])
        XCTAssertEqual(merged.library.documents[1].original.artist, "Refreshed second file")
        XCTAssertEqual(merged.refreshedIDs, [first.id, second.id])
    }

    func testImportMergeRebasesDraftAndRetainsCoverAttributionAndFolderMembership() {
        let cover = AudioArtwork(data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let attribution = ShazamAttribution(title: "Recognized title", artist: "Recognized artist")
        var existing = AudioDocument(url: root.appendingPathComponent("song.mp3"), bookmark: nil,
                                     original: AudioTags(title: "Original", artist: "Original artist"),
                                     draft: AudioTags(title: "My pending title", artist: "Original artist"),
                                     duration: 1, error: nil, sourceHash: "same",
                                     draftArtwork: cover, importFolderIDs: ["old-folder"],
                                     originalShazamAttribution: attribution, draftShazamAttribution: attribution)
        for hash in ["same", "changed"] {
            var incoming = existing
            incoming.id = UUID()
            incoming.original.artist = "Updated file artist"
            incoming.draft = incoming.original
            incoming.sourceHash = hash
            incoming.draftArtwork = nil
            incoming.originalShazamAttribution = nil
            incoming.draftShazamAttribution = nil
            incoming.importFolderIDs = ["new-folder"]
            let merged = LibraryImportMerge(ImportResult(documents: [incoming], failures: []),
                                            into: AudioLibrary(documents: [existing], folders: []))
            let refreshed = merged.library.documents[0]
            XCTAssertEqual(refreshed.id, existing.id)
            XCTAssertEqual(refreshed.draft.title, existing.draft.title)
            XCTAssertEqual(refreshed.draft.artist, incoming.original.artist)
            XCTAssertEqual(refreshed.draftArtwork, cover)
            XCTAssertEqual(refreshed.importFolderIDs, ["old-folder", "new-folder"])
            XCTAssertEqual(refreshed.draftShazamAttribution, attribution)
            XCTAssertEqual(refreshed.originalShazamAttribution, hash == "same" ? attribution : nil)
            XCTAssertEqual(merged.refreshedDrafts, 1)
        }
        // An unchanged file must not be reported as a retained pending draft.
        existing.draft = existing.original
        existing.draftArtwork = existing.originalArtwork
        let merged = LibraryImportMerge(ImportResult(documents: [existing], failures: []),
                                        into: AudioLibrary(documents: [existing], folders: []))
        XCTAssertEqual(merged.refreshedDrafts, 0)
    }

    @MainActor
    func testMixedImportsAndEmptyFoldersRemainGroupedAfterReload() async throws {
        let album = try directory("Album")
        let disc = try directory("Album/Disc 2")
        let empty = try directory("Empty")
        let direct = try audio("Single", in: root)
        let first = try audio("First", in: album)
        let nested = try audio("Second", in: disc)
        let model = await loadedModel()

        model.importFiles([direct, album, empty])
        try await waitUntilIdle(model)

        XCTAssertNil(model.notice)
        XCTAssertEqual(model.standaloneDocuments.map(\.fileName), [direct.lastPathComponent])
        XCTAssertEqual(model.folders.count, 2)
        let importedAlbum = try XCTUnwrap(model.folders.first { $0.name == "Album" })
        let importedEmpty = try XCTUnwrap(model.folders.first { $0.name == "Empty" })
        XCTAssertEqual(Set(model.documents(in: importedAlbum).map(\.fileName)),
                       [first.lastPathComponent, nested.lastPathComponent])
        XCTAssertTrue(model.documents(in: importedEmpty).isEmpty)

        let reloaded = await loadedModel()
        XCTAssertNil(reloaded.notice)
        XCTAssertEqual(reloaded.folders, model.folders)
        XCTAssertEqual(Set(reloaded.documents.map(\.id)), Set(model.documents.map(\.id)))
        XCTAssertEqual(reloaded.standaloneDocuments.map(\.fileName), [direct.lastPathComponent])
        XCTAssertEqual(reloaded.documents(in: importedAlbum).count, 2)
        XCTAssertTrue(reloaded.documents(in: importedEmpty).isEmpty)
    }

    @MainActor
    func testReimportingFolderAndIndividualFileKeepsDraftAndMembership() async throws {
        let album = try directory("Album")
        let song = try audio("Song", in: album)
        let model = await loadedModel()
        model.importFiles([album])
        try await waitUntilIdle(model)
        let original = try XCTUnwrap(model.documents.first)
        let folder = try XCTUnwrap(model.folders.first)
        var edited = original.draft
        edited.title = "My pending title"

        // Reimporting an externally changed source must keep the existing local copy and draft.
        var external = original.original
        external.artist = "External artist"
        try NativeMetadataCodec().write(external, to: song)
        model.updateDraft(edited, for: original.id)
        model.importFiles([song])
        try await waitUntilIdle(model)
        model.importFiles([album])
        try await waitUntilIdle(model)

        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.folders.count, 1)
        XCTAssertTrue(model.standaloneDocuments.isEmpty)
        let refreshed = try XCTUnwrap(model.documents(in: folder).first)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.importFolderIDs, [folder.id])
        XCTAssertEqual(refreshed.draft.title, "My pending title")
        XCTAssertEqual(refreshed.original.title, original.original.title)
        XCTAssertEqual(refreshed.draft.artist, original.original.artist)
        XCTAssertEqual(refreshed.url, original.url)
        XCTAssertEqual(try NativeMetadataCodec().read(from: song).tags, external,
                       "Refreshing a draft must not write it to the source file")

        let reloaded = await loadedModel()
        XCTAssertEqual(reloaded.documents(in: folder).first?.draft, refreshed.draft)
        XCTAssertEqual(reloaded.documents.first?.id, original.id)
    }

    @MainActor
    func testRemovingOverlappingFolderPreservesOtherMembershipAndOriginalFiles() async throws {
        let album = try directory("Album")
        let disc = try directory("Album/Disc 2")
        let empty = try directory("Empty")
        let direct = try audio("Single", in: root)
        let first = try audio("First", in: album)
        let shared = try audio("Shared", in: disc)
        let originalBytes = try Data(contentsOf: shared)
        let model = await loadedModel()
        model.importFiles([direct, album, disc, empty])
        try await waitUntilIdle(model)
        let parentFolder = try XCTUnwrap(model.folders.first { $0.name == "Album" })
        let childFolder = try XCTUnwrap(model.folders.first { $0.name == "Disc 2" })
        let sharedID = try XCTUnwrap(model.documents(in: childFolder).first?.id)

        model.removeFolder(parentFolder)
        await flushScheduledPersistence(model)

        XCTAssertEqual(model.documents.count, 2)
        XCTAssertEqual(model.documents(in: childFolder).map(\.id), [sharedID])
        XCTAssertEqual(model.document(sharedID)?.importFolderIDs, [childFolder.id])
        XCTAssertEqual(model.standaloneDocuments.map(\.fileName), [direct.lastPathComponent])
        XCTAssertEqual(Set(model.folders.map(\.name)), ["Disc 2", "Empty"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: shared), originalBytes)

        let reloaded = await loadedModel()
        XCTAssertEqual(Set(reloaded.folders.map(\.name)), ["Disc 2", "Empty"])
        XCTAssertEqual(reloaded.documents(in: childFolder).map(\.id), [sharedID])
        model.removeFolder(childFolder)
        await flushScheduledPersistence(model)
        XCTAssertEqual(model.documents.map(\.fileName), [direct.lastPathComponent])
        XCTAssertEqual(model.folders.map(\.name), ["Empty"])
        XCTAssertEqual(try Data(contentsOf: shared), originalBytes)
    }

    @MainActor
    func testImmediateRestoreAfterRemovingFolderReturnsVisibleStandaloneFile() async throws {
        let album = try directory("Album")
        let song = try audio("Song", in: album)
        let originalBytes = try Data(contentsOf: song)
        let model = await loadedModel()
        model.importFiles([album])
        try await waitUntilIdle(model)
        let document = try XCTUnwrap(model.documents.first)
        let folder = try XCTUnwrap(model.folders.first)
        var edited = document.draft
        edited.title = "Saved title"
        model.updateDraft(edited, for: document.id)
        model.save([document.id])
        try await waitUntilIdle(model)
        XCTAssertNil(model.notice)
        let backup = try XCTUnwrap(model.backupRecords.first)
        XCTAssertNotEqual(try Data(contentsOf: document.url), originalBytes)
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)

        // Restore starts before the removed folder has reached the debounced index.
        model.removeFolder(folder)
        model.restore(backup)
        try await waitUntilIdle(model)

        XCTAssertNil(model.notice)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertEqual(model.standaloneDocuments.map(\.id), [document.id])
        XCTAssertEqual(try Data(contentsOf: song), originalBytes)
        XCTAssertEqual(try Data(contentsOf: document.url), originalBytes)
        let reloaded = await loadedModel()
        XCTAssertTrue(reloaded.folders.isEmpty)
        XCTAssertEqual(reloaded.standaloneDocuments.map(\.id), [document.id])
    }

    @MainActor
    func testReimportAfterFailedLegacyMigrationKeepsOneDocumentAndItsDraft() async throws {
        let album = try directory("Legacy Album")
        let source = try audio("Legacy Song", in: album)
        let bytes = try Data(contentsOf: source)
        let snapshot = try NativeMetadataCodec().read(from: source)
        let folder = AudioFolder(url: album)
        var legacy = AudioDocument(url: source, bookmark: nil, original: snapshot.tags, draft: snapshot.tags,
                                   duration: snapshot.duration, error: nil, sourceHash: try AudioFileStore.fileHash(source),
                                   originalArtwork: snapshot.artwork, draftArtwork: snapshot.artwork,
                                   importFolderIDs: [folder.id])
        legacy.draft.title = "Keep my pending draft"
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: root.appendingPathComponent("State"))
        try await store.persistLibrary(AudioLibrary(documents: [legacy], folders: [folder]))
        try FileManager.default.removeItem(at: source)
        let model = await loadedModel()
        XCTAssertNotNil(model.documents.first?.error)
        try bytes.write(to: source)

        model.importFiles([album])
        try await waitUntilIdle(model)

        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.folders.count, 1)
        let recovered = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(recovered.id, legacy.id)
        XCTAssertEqual(recovered.draft, legacy.draft)
        XCTAssertEqual(recovered.importFolderIDs, legacy.importFolderIDs)
        XCTAssertNotEqual(recovered.url, source)
        XCTAssertNil(recovered.error)
        let relaunched = await loadedModel()
        XCTAssertEqual(relaunched.documents.first?.draft, legacy.draft)
        XCTAssertEqual(relaunched.documents.count, 1)
    }

    @MainActor
    func testCancellingLocalDeletionPreservesFileDraftAndLibraryAcrossRelaunch() async throws {
        let source = try audio("Keep", in: root)
        let model = await loadedModel()
        model.importFiles([source])
        try await waitUntilIdle(model)
        let document = try XCTUnwrap(model.documents.first)
        var draft = document.draft
        draft.title = "Keep my unsaved title"
        model.updateDraft(draft, for: document.id)
        let originalBytes = try Data(contentsOf: document.url)

        model.prepareDeletion(documentIDs: [document.id])
        try await waitForDeletionPlan(model)
        XCTAssertEqual(model.deletionPlan?.fileCount, 1)
        model.cancelDeletion()
        await flushScheduledPersistence(model)

        XCTAssertNil(model.deletionPlan)
        XCTAssertEqual(try Data(contentsOf: document.url), originalBytes)
        XCTAssertEqual(model.document(document.id)?.draft, draft)
        let reloaded = await loadedModel()
        XCTAssertEqual(reloaded.document(document.id)?.draft, draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testBatchLocalDeletionRemovesSelectedFilesAndPreservesOtherPendingDraft() async throws {
        let first = try audio("First", in: root)
        let second = try audio("Second", in: root)
        let keep = try audio("Keep", in: root)
        let model = await loadedModel()
        model.importFiles([first, second, keep])
        try await waitUntilIdle(model)
        let survivor = try XCTUnwrap(model.documents.first { $0.fileName == keep.lastPathComponent })
        let removed = model.documents.filter { $0.id != survivor.id }
        var draft = survivor.draft
        draft.artist = "Unsaved survivor"
        model.updateDraft(draft, for: survivor.id)

        model.prepareDeletion(documentIDs: Set(removed.map(\.id)))
        try await waitForDeletionPlan(model)
        XCTAssertEqual(model.deletionPlan?.fileCount, 2)
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.documents.map(\.id), [survivor.id])
        XCTAssertEqual(model.documents.first?.draft, draft)
        for document in removed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.path))
        }
        for source in [first, second, keep] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Sources must remain unchanged")
        }
        let reloaded = await loadedModel()
        XCTAssertEqual(reloaded.documents.map(\.id), [survivor.id])
        XCTAssertEqual(reloaded.documents.first?.draft, draft)
        reloaded.importFiles([first])
        try await waitUntilIdle(reloaded)
        XCTAssertEqual(reloaded.documents.count, 2, "Deleted files must be importable again")
        XCTAssertEqual(reloaded.document(survivor.id)?.draft, draft)
        let importedAgain = try XCTUnwrap(reloaded.documents.first { $0.fileName == first.lastPathComponent })
        XCTAssertFalse(removed.map(\.id).contains(importedAgain.id))
        XCTAssertFalse(importedAgain.hasChanges)
    }

    @MainActor
    func testMixedBatchDeletionRemovesNestedAndEmptyFoldersWithoutDeletingSources() async throws {
        let album = try directory("Album")
        let disc = try directory("Album/Disc 2")
        let empty = try directory("Empty")
        let other = try directory("Other")
        let direct = try audio("Single", in: root)
        let first = try audio("First", in: album)
        let nested = try audio("Nested", in: disc)
        let keep = try audio("Keep", in: other)
        let model = await loadedModel()
        model.importFiles([direct, album, disc, empty, other])
        try await waitUntilIdle(model)
        let selectedFolders = model.folders.filter { $0.name != "Other" }
        XCTAssertEqual(selectedFolders.count, 3)
        let directDocument = try XCTUnwrap(model.documents.first { $0.fileName == direct.lastPathComponent })
        let survivingDocument = try XCTUnwrap(model.documents.first { $0.fileName == keep.lastPathComponent })
        let parent = try XCTUnwrap(selectedFolders.first { $0.name == "Album" })
        let unlistedFile = parent.url.appendingPathComponent("Notes.txt")
        try Data("A local file not indexed in the music list".utf8).write(to: unlistedFile)

        model.prepareDeletion(documentIDs: [directDocument.id], folderIDs: Set(selectedFolders.map(\.id)))
        try await waitForDeletionPlan(model)
        XCTAssertEqual(model.deletionPlan?.fileCount, 4, "Nested folder selections must be deduplicated")
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertEqual(model.documents.map(\.id), [survivingDocument.id])
        XCTAssertEqual(model.folders.map(\.name), ["Other"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directDocument.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlistedFile.path))
        for folder in selectedFolders { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path)) }
        for source in [direct, first, nested, keep] { XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))

        let reloaded = await loadedModel()
        XCTAssertEqual(reloaded.documents.map(\.id), [survivingDocument.id])
        XCTAssertEqual(reloaded.folders.map(\.name), ["Other"])
    }

    @MainActor
    func testDeletingSharedFileRemovesAllFolderReferencesButKeepsFolders() async throws {
        let parent = try directory("Album")
        let child = try directory("Album/Disc 2")
        _ = try audio("Shared", in: child)
        let model = await loadedModel()
        model.importFiles([parent, child])
        try await waitUntilIdle(model)
        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(document.importFolderIDs?.count, 2)
        let folderIDs = Set(model.folders.map(\.id))

        model.prepareDeletion(documentIDs: [document.id])
        try await waitForDeletionPlan(model)
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(Set(model.folders.map(\.id)), folderIDs)
        for folder in model.folders { XCTAssertTrue(model.documents(in: folder).isEmpty) }
        let reloaded = await loadedModel()
        XCTAssertTrue(reloaded.documents.isEmpty)
        XCTAssertEqual(Set(reloaded.folders.map(\.id)), folderIDs)
    }

    @MainActor
    func testActualLocalBrowserCanDeleteAFileAlreadyRemovedFromLibrary() async throws {
        let source = try audio("Hidden local copy", in: root)
        let model = await loadedModel()
        model.importFiles([source])
        try await waitUntilIdle(model)
        let document = try XCTUnwrap(model.documents.first)
        model.remove([document.id])
        await flushScheduledPersistence(model)
        XCTAssertTrue(model.documents.isEmpty)
        let localEntries = try await model.localFiles(in: document.url.deletingLastPathComponent())
        XCTAssertTrue(localEntries.contains { $0.url == document.url })

        model.prepareDeletion(urls: [document.url])
        try await waitForDeletionPlan(model)
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        model.enqueueLocalImports([model.localLibraryDirectory])
        try await waitUntilIdle(model)
        XCTAssertTrue(model.documents.isEmpty, "Refreshing must not restore a deleted local file")
        let reloaded = await loadedModel()
        XCTAssertTrue(reloaded.documents.isEmpty)
    }

    @MainActor
    func testDeletingSavedSongRetainsBackupAndMarksItsAudioMissing() async throws {
        let source = try audio("Saved song", in: root)
        let model = await loadedModel()
        model.importFiles([source])
        try await waitUntilIdle(model)
        let document = try XCTUnwrap(model.documents.first)
        var draft = document.draft
        draft.title = "Saved before deletion"
        model.updateDraft(draft, for: document.id)
        model.save([document.id])
        try await waitUntilIdle(model)
        let backup = try XCTUnwrap(model.backupRecords.first)

        model.prepareDeletion(documentIDs: [document.id])
        try await waitForDeletionPlan(model)
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(model.backupRecords.map(\.id), [backup.id])
        XCTAssertTrue(model.missingBackupAudioIDs.contains(backup.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.backupURL.path))
        let reloaded = await loadedModel()
        XCTAssertEqual(reloaded.backupRecords.map(\.id), [backup.id])
        XCTAssertTrue(reloaded.missingBackupAudioIDs.contains(backup.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testQueuedImportForDeletedFolderCannotRecreateItsDirectoryOrListEntry() async throws {
        let model = await loadedModel()
        let download = model.localLibraryDirectory.appendingPathComponent("Connections/Downloaded Album", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        _ = try audio("Downloaded song", in: download)
        model.enqueueLocalImports([download])
        try await waitUntilIdle(model)
        let folder = try XCTUnwrap(model.folders.first)
        model.prepareDeletion(folderIDs: [folder.id])
        try await waitForDeletionPlan(model)

        // Model the delayed notification from a completed transfer while its
        // deletion confirmation is still open.
        model.enqueueLocalImports([download])
        XCTAssertEqual(model.documents.count, 1)
        model.confirmDeletion()
        try await waitUntilIdle(model)

        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        let reloaded = await loadedModel()
        XCTAssertTrue(reloaded.documents.isEmpty)
        XCTAssertTrue(reloaded.folders.isEmpty)
    }

    @MainActor
    private func waitForDeletionPlan(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isPreparingDeletion, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.deletionPlan != nil else {
            XCTFail("Deletion preview did not become available: \(model.notice ?? "no error")")
            throw URLError(.timedOut)
        }
    }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audio(_ name: String, in directory: URL) throws -> URL {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "m4a", subdirectory: "Fixtures"))
        let url = directory.appendingPathComponent(name).appendingPathExtension("m4a")
        try FileManager.default.copyItem(at: fixture, to: url)
        return url
    }

    @MainActor
    private func loadedModel() async -> AppModel {
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: root.appendingPathComponent("State"))
        let model = AppModel(fileStore: store)
        await model.load()
        return model
    }

    @MainActor
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isWorking, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !model.isWorking else {
            model.cancelOperation()
            XCTFail("The import did not complete before the deadline")
            throw URLError(.timedOut)
        }
    }

    @MainActor
    private func flushScheduledPersistence(_ model: AppModel) async {
        // Let the 300 ms draft debounce finish before removing this test's storage.
        try? await Task.sleep(for: .milliseconds(400))
        await model.persistNow()
    }
}
