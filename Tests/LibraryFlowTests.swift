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
