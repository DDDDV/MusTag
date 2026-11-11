import Foundation
import XCTest
@testable import MusTag

final class LocalFileDeletionTests: XCTestCase {
    private var root: URL!
    private var state: URL { root.appendingPathComponent("State", isDirectory: true) }
    private var music: URL { state.appendingPathComponent("Music", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMixedFolderAndFilePreviewDeduplicatesDescendantsAndCountsEveryFile() async throws {
        let parent = music.appendingPathComponent("Album", isDirectory: true)
        let nested = parent.appendingPathComponent("Disc", isDirectory: true)
        let empty = parent.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let song = try file("Album/Disc/song.mp3", bytes: Data(repeating: 1, count: 20))
        _ = try file("Album/.notes", bytes: Data(repeating: 2, count: 3))
        let loose = try file("loose.txt", bytes: Data(repeating: 3, count: 7))

        let plan = try await store().prepareDeletion(urls: [song, nested, parent, parent, loose])

        XCTAssertEqual(plan.roots.count, 2)
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.folderCount, 3)
        XCTAssertEqual(plan.totalBytes, 30)
    }

    func testBatchFoldersDeleteNestedHiddenUnsupportedAndEmptyContents() async throws {
        let first = music.appendingPathComponent("One", isDirectory: true)
        let second = music.appendingPathComponent("Two", isDirectory: true)
        let empty = second.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = try file("One/song.mp3")
        _ = try file("One/Disc/.artwork")
        _ = try file("Two/readme.txt")
        let kept = try file("Keep/song.mp3")
        let store = store()

        let plan = try await store.prepareDeletion(urls: [first, second, empty])
        let result = try await store.deleteLocalFiles(plan)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.deletedFileCount, 3)
        XCTAssertEqual(result.deletedFolderCount, 4)
        XCTAssertFalse(exists(first))
        XCTAssertFalse(exists(second))
        XCTAssertTrue(exists(kept))
        XCTAssertFalse(exists(state.appendingPathComponent("pending-deletion.json")))
    }

    func testDeletesAllAliasesAndGroupsButPreservesSourceAndOtherFiles() async throws {
        let source = try audio("Source/song.mp3")
        let other = try audio("Source/other.mp3")
        let store = store()
        let imported = try await store.importFiles(from: [source, other])
        var song = try XCTUnwrap(imported.documents.first { $0.fileName == "song.mp3" })
        let kept = try XCTUnwrap(imported.documents.first { $0.fileName == "other.mp3" })
        let one = AudioFolder(url: music.appendingPathComponent("Group1", isDirectory: true))
        let two = AudioFolder(url: music.appendingPathComponent("Group2", isDirectory: true))
        song.importFolderIDs = [one.id, two.id]
        song.draft.title = "Unwritten draft"
        var alias = song
        alias.id = UUID()
        try await store.persistLibrary(AudioLibrary(documents: [song, alias, kept], folders: [one, two]))

        let plan = try await store.prepareDeletion(urls: [song.url, alias.url])
        let result = try await store.deleteLocalFiles(plan)
        let reloaded = try await self.store().loadLibrary()

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.library.documents.map(\.id), [kept.id])
        XCTAssertEqual(reloaded.documents.map(\.id), [kept.id])
        XCTAssertTrue(exists(source))
        XCTAssertTrue(exists(other))
        XCTAssertTrue(exists(kept.url))
        XCTAssertFalse(exists(song.url))
    }

    func testFolderDeletionRemovesAllNestedIndexesAndAllowsFreshImport() async throws {
        let source = try audio("External/Album/Disc/song.mp3")
        let album = source.deletingLastPathComponent().deletingLastPathComponent()
        let store = store()
        let imported = try await store.importFiles(from: [album, source.deletingLastPathComponent()])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let parent = try XCTUnwrap(imported.folders.first { $0.name == "Album" })
        let song = try XCTUnwrap(imported.documents.first)
        try json(["remote-one": song.libraryRelativePath!, "remote-two": song.libraryRelativePath!, "keep": "Other/song.mp3"],
                 to: state.appendingPathComponent("downloads.json"))

        let plan = try await store.prepareDeletion(urls: [parent.url])
        let result = try await store.deleteLocalFiles(plan)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.library.documents.isEmpty)
        XCTAssertTrue(result.library.folders.isEmpty)
        let downloads = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: state.appendingPathComponent("downloads.json")))
        XCTAssertEqual(downloads, ["keep": "Other/song.mp3"])
        let locations = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: state.appendingPathComponent("imports.json")))
        XCTAssertTrue(locations["files"]?.isEmpty == true)
        XCTAssertTrue(locations["folders"]?.isEmpty == true)
        XCTAssertTrue(exists(source))
        let repeated = try await store.importFiles(from: [album])
        XCTAssertEqual(repeated.documents.count, 1)
        XCTAssertTrue(repeated.failures.isEmpty)
        XCTAssertNotEqual(repeated.documents.first?.id, song.id)
        XCTAssertTrue(exists(try XCTUnwrap(repeated.documents.first).url))
    }

    func testFileReplacedAfterPreviewIsKeptAndOtherSelectionStillDeletes() async throws {
        let replaced = try file("replaced.mp3")
        let other = try file("other.mp3")
        let store = store()
        let plan = try await store.prepareDeletion(urls: [replaced, other])
        let replacement = Data("different contents".utf8)
        try replacement.write(to: replaced, options: .atomic)

        let result = try await store.deleteLocalFiles(plan)

        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: replaced), replacement)
        XCTAssertFalse(exists(other))
    }

    func testNewFileAddedAfterFolderPreviewSurvivesAndFolderIsKept() async throws {
        let original = try file("Album/song.mp3")
        let folder = original.deletingLastPathComponent()
        let store = store()
        let plan = try await store.prepareDeletion(urls: [folder])
        let added = try file("Album/new.mp3")

        let result = try await store.deleteLocalFiles(plan)

        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.deletedFolderCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(exists(original))
        XCTAssertTrue(exists(folder))
        XCTAssertTrue(exists(added))
    }

    func testReplacedFolderDoesNotRedirectConfirmedDeletion() async throws {
        let original = try file("Album/song.mp3")
        let folder = original.deletingLastPathComponent()
        let store = store()
        let plan = try await store.prepareDeletion(urls: [folder])
        let moved = music.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        let replacement = try file("Album/song.mp3", bytes: Data("new song".utf8))

        let result = try await store.deleteLocalFiles(plan)

        XCTAssertEqual(result.deletedFileCount, 0)
        XCTAssertEqual(result.deletedFolderCount, 0)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(exists(replacement))
        XCTAssertTrue(exists(moved.appendingPathComponent("song.mp3")))
    }

    func testAlreadyMissingFileCleansStaleLibraryRecord() async throws {
        let source = try audio("source.mp3")
        let store = store()
        let imported = try await store.importFiles(from: [source])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: []))
        let local = try XCTUnwrap(imported.documents.first).url
        try FileManager.default.removeItem(at: local)

        let plan = try await store.prepareDeletion(urls: [local])
        let result = try await store.deleteLocalFiles(plan)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.library.documents.isEmpty)
        XCTAssertTrue(exists(source))
    }

    func testAlreadyMissingFolderCleansNestedRecords() async throws {
        let source = try audio("External/Album/Disc/song.mp3")
        let store = store()
        let imported = try await store.importFiles(from: [source.deletingLastPathComponent().deletingLastPathComponent()])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let folder = try XCTUnwrap(imported.folders.first).url
        try FileManager.default.removeItem(at: folder)

        let plan = try await store.prepareDeletion(urls: [folder])
        let result = try await store.deleteLocalFiles(plan)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.library.documents.isEmpty)
        XCTAssertTrue(result.library.folders.isEmpty)
    }

    func testPendingDeletionReplaysAfterFilesDeletedBeforeIndexesWereWritten() async throws {
        let source = try audio("External/Album/Disc/song.mp3")
        let store = store()
        let imported = try await store.importFiles(from: [source.deletingLastPathComponent().deletingLastPathComponent()])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let folder = try XCTUnwrap(imported.folders.first).url
        let local = try XCTUnwrap(imported.documents.first).url
        let plan = try await store.prepareDeletion(urls: [folder])
        try json(plan, to: state.appendingPathComponent("pending-deletion.json"))
        try FileManager.default.removeItem(at: local)

        let reloaded = try await self.store().loadLibrary()

        XCTAssertTrue(reloaded.documents.isEmpty)
        XCTAssertTrue(reloaded.folders.isEmpty)
        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(state.appendingPathComponent("pending-deletion.json")))
        XCTAssertTrue(exists(source))
    }

    func testCorruptIndexPreventsDeletingAnyFile() async throws {
        let song = try file("song.mp3")
        let store = store()
        let plan = try await store.prepareDeletion(urls: [song])
        try Data("broken index".utf8).write(to: state.appendingPathComponent("downloads.json"))

        do {
            _ = try await store.deleteLocalFiles(plan)
            XCTFail("Corrupt indexes must prevent physical deletion")
        } catch { }

        XCTAssertTrue(exists(song))
        XCTAssertFalse(exists(state.appendingPathComponent("pending-deletion.json")))
    }

    func testRootOutsideAndSymlinkAreRejectedWithoutChangingSource() async throws {
        let external = try audio("External/song.mp3")
        let link = music.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let linkedDirectory = music.appendingPathComponent("linked-folder", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: external.deletingLastPathComponent())
        let store = store()

        for target in [music, external, link, linkedDirectory, linkedDirectory.appendingPathComponent("song.mp3")] {
            do {
                _ = try await store.prepareDeletion(urls: [target])
                XCTFail("Unsafe target must be rejected: \(target)")
            } catch { }
        }
        XCTAssertTrue(exists(external))
    }

    func testSymlinkInsertedAfterPreviewNeverDeletesExternalFile() async throws {
        let local = try file("Album/song.mp3")
        let external = try audio("External/song.mp3")
        let folder = local.deletingLastPathComponent()
        let store = store()
        let plan = try await store.prepareDeletion(urls: [local])
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: external.deletingLastPathComponent())

        do {
            _ = try await store.deleteLocalFiles(plan)
            XCTFail("Replaced symlink parent must be rejected")
        } catch { }
        XCTAssertTrue(exists(external))
    }

    func testBrowserIncludesUnindexedFilesAndEmptyFoldersButExcludesLinks() async throws {
        let song = try file("unlisted.mp3")
        let notes = try file("notes.txt")
        let folder = music.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("link"), withDestinationURL: song)

        let entries = try await store().localFiles(in: music)

        XCTAssertEqual(Set(entries.map(\.url)), [song, notes, folder])
        XCTAssertTrue(entries.first?.isDirectory == true)
        XCTAssertEqual(entries.first?.name, "Empty")
    }

    func testDeletionRetainsMetadataBackupAndReportsMissingAudio() async throws {
        let source = try audio("source.mp3")
        let store = store()
        let imported = try await store.importFiles(from: [source])
        var document = try XCTUnwrap(imported.documents.first)
        document.draft.title = "Saved edit"
        let (saved, backup) = try await store.save(document)
        let before = await store.backupAudioExists(backup)
        XCTAssertTrue(before)
        var legacy = backup
        legacy.originalURL = source
        legacy.libraryRelativePath = nil
        legacy.bookmark = nil
        let migratedLegacyIsAvailable = await store.backupAudioExists(legacy)
        XCTAssertTrue(migratedLegacyIsAvailable, "A migrated legacy backup must use the same local lookup as restore")

        let plan = try await store.prepareDeletion(urls: [saved.url])
        let result = try await store.deleteLocalFiles(plan)
        let backups = try await store.backups()
        let after = await store.backupAudioExists(backup)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(backups.map(\.id), [backup.id])
        XCTAssertTrue(exists(backup.backupURL))
        XCTAssertFalse(after)
        XCTAssertTrue(exists(source))
    }

    private func store() -> AudioFileStore {
        AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state)
    }

    private func file(_ path: String, bytes: Data = Data("local file".utf8)) throws -> URL {
        let url = music.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func audio(_ path: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp3", subdirectory: "Fixtures"))
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func json<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
