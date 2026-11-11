import Combine
import Foundation
import XCTest
@testable import MusTag

final class ConnectionDownloadTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("Music", isDirectory: true) }
    private var state: URL { root.appendingPathComponent("State", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionDownloadTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testManifestSurvivesRelaunchAndNeverOverwritesEditedLocalCopy() async throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        let connection = connection()
        let file = RemoteFile(id: "/remote/song", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        let repository = repository()
        let staged = try stage(original)
        let local = try await repository.accept(staged, connection: connection, file: file,
                                                relativeComponents: ["Album", file.name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: local), original)
        var tags = try NativeMetadataCodec().read(from: local).tags
        tags.title = "Edited only in the local library"
        try NativeMetadataCodec().write(tags, to: local)
        let edited = try Data(contentsOf: local)
        XCTAssertNotEqual(edited, original)

        let reopened = self.repository()
        let existing = try await reopened.existingFile(connection: connection, file: file)
        XCTAssertEqual(existing, local)
        let retry = try stage(original)
        let repeated = try await reopened.accept(retry, connection: connection, file: file,
                                                 relativeComponents: ["Album", file.name])
        XCTAssertEqual(repeated, local)
        XCTAssertEqual(try Data(contentsOf: local), edited)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try audioFiles(in: library), [local])
        // The owner of a download's staging file cleans up a duplicate download.
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.path))
        let manifest = try String(contentsOf: state.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(connection.address))
        XCTAssertFalse(manifest.contains(connection.username))
        XCTAssertFalse(manifest.contains(file.id))
    }

    func testDeletingDownloadedFileInvalidatesExistingRepositoryAndAllowsRedownload() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let file = RemoteFile(id: "/song", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        let local = try await repository.accept(stage(original), connection: connection, file: file,
                                                relativeComponents: ["Album", file.name])
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state, libraryDirectory: library)
        let imported = try await store.importFiles(from: [local])
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: imported.folders))
        let plan = try await store.prepareDeletion(urls: [local])

        _ = try await store.deleteLocalFiles(plan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        let existing = try await repository.existingFile(connection: connection, file: file)
        XCTAssertNil(existing, "The live repository must not reuse a deleted download")
        let manifest = try JSONDecoder().decode([String: String].self,
                                               from: Data(contentsOf: state.appendingPathComponent("downloads.json")))
        XCTAssertTrue(manifest.isEmpty)

        let redownloaded = try await repository.accept(stage(original), connection: connection, file: file,
                                                       relativeComponents: ["Album", file.name])
        XCTAssertEqual(redownloaded, local, "Deletion should release the original destination name")
        XCTAssertEqual(try Data(contentsOf: redownloaded), original)
        let refreshed = try await store.importFiles(from: [redownloaded])
        XCTAssertEqual(refreshed.documents.count, 1)
        XCTAssertTrue(refreshed.failures.isEmpty)
        XCTAssertEqual(try audioFiles(in: library), [redownloaded])
    }

    func testFolderDeletionDoesNotResurrectOldManifestEntriesWhenAnotherRepositoryWrites() async throws {
        let original = try Data(contentsOf: fixture())
        let firstRepository = repository()
        let otherRepository = repository()
        let connection = connection()
        let deleted = RemoteFile(id: "/delete", name: "Delete.mp3", isDirectory: false, size: Int64(original.count))
        let kept = RemoteFile(id: "/keep", name: "Keep.mp3", isDirectory: false, size: Int64(original.count))
        let deletedURL = try await firstRepository.accept(stage(original), connection: connection, file: deleted,
                                                          relativeComponents: ["Deleted Album", deleted.name])
        _ = try await otherRepository.existingFile(connection: connection, file: deleted)
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state, libraryDirectory: library)
        let plan = try await store.prepareDeletion(urls: [deletedURL.deletingLastPathComponent()])

        _ = try await store.deleteLocalFiles(plan)
        let keptURL = try await otherRepository.accept(stage(original), connection: connection, file: kept,
                                                       relativeComponents: ["Kept Album", kept.name])

        let manifest = try JSONDecoder().decode([String: String].self,
                                               from: Data(contentsOf: state.appendingPathComponent("downloads.json")))
        XCTAssertEqual(manifest.count, 1, "A cached manifest must not rewrite the deleted entry")
        XCTAssertFalse(manifest.values.contains { $0.contains("Deleted Album") })
        let available = try await firstRepository.existingFile(connection: connection, file: kept)
        XCTAssertEqual(available, keptURL, "Repositories must observe each other's latest accepted files")
        XCTAssertEqual(try audioFiles(in: library), [keptURL])
    }

    func testDifferentRemoteFilesWithSameNameAreBothKept() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let first = RemoteFile(id: "/one", name: "Same.mp3", isDirectory: false, size: Int64(original.count))
        let second = RemoteFile(id: "/two", name: "Same.mp3", isDirectory: false, size: Int64(original.count))
        let firstURL = try await repository.accept(stage(original), connection: connection, file: first,
                                                   relativeComponents: ["Album", "Same.mp3"])
        let secondURL = try await repository.accept(stage(original), connection: connection, file: second,
                                                    relativeComponents: ["Album", "Same.mp3"])
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL.lastPathComponent, "Same.mp3")
        XCTAssertEqual(secondURL.lastPathComponent, "Same (2).mp3")
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        XCTAssertEqual(try Data(contentsOf: secondURL), original)
        let firstExisting = try await repository.existingFile(connection: connection, file: first)
        let secondExisting = try await repository.existingFile(connection: connection, file: second)
        XCTAssertEqual(firstExisting, firstURL)
        XCTAssertEqual(secondExisting, secondURL)
    }

    func testSameServerFileInDifferentAccountsHasSeparateLocalIdentity() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let first = connection()
        let second = connection()
        let file = RemoteFile(id: "/same", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        let firstURL = try await repository.accept(stage(original), connection: first, file: file, relativeComponents: [file.name])
        let secondURL = try await repository.accept(stage(original), connection: second, file: file, relativeComponents: [file.name])
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        XCTAssertEqual(try Data(contentsOf: secondURL), original)
    }

    func testChangingAccountWithinSavedConnectionDoesNotReuseAnotherUsersFile() async throws {
        let bytes = try Data(contentsOf: fixture())
        let repository = repository()
        let first = connection()
        let file = RemoteFile(id: "/same/song.mp3", name: "Song.mp3", isDirectory: false, size: Int64(bytes.count))
        let firstURL = try await repository.accept(stage(bytes), connection: first, file: file, relativeComponents: [file.name])
        var second = first
        second.username = first.username + "-another-user"
        let reused = try await repository.existingFile(connection: second, file: file)
        XCTAssertNil(reused)
        let secondURL = try await repository.accept(stage(bytes), connection: second, file: file, relativeComponents: [file.name])
        XCTAssertNotEqual(firstURL, secondURL)
        var third = second
        third.domain = "OtherDomain"
        let reusedDomain = try await repository.existingFile(connection: third, file: file)
        XCTAssertNil(reusedDomain)
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
    }

    func testIncompleteAndNonAudioDownloadsNeverEnterLibrary() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let cases: [(Data, Int64?)] = [
            (Data(original.dropLast(10)), Int64(original.count)),
            (Data(), 0),
            (Data("<html>authentication failed</html>".utf8), nil)
        ]
        for (index, item) in cases.enumerated() {
            let staged = try stage(item.0)
            let file = RemoteFile(id: "/invalid-\(index)", name: "Song.mp3", isDirectory: false, size: item.1)
            do {
                _ = try await repository.accept(staged, connection: connection, file: file, relativeComponents: [file.name])
                XCTFail("Invalid download \(index) must not be accepted")
            } catch { }
            let existing = try await repository.existingFile(connection: connection, file: file)
            XCTAssertNil(existing)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        }
        XCTAssertTrue(try audioFiles(in: library).isEmpty)
    }

    func testTruncatedAudioWithMatchingTransferSizeIsRejected() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "truncated", withExtension: "mp3", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: source)
        let staged = try stage(bytes)
        let file = RemoteFile(id: "/broken", name: "Broken.mp3", isDirectory: false, size: Int64(bytes.count))
        do {
            _ = try await repository().accept(staged, connection: connection(), file: file, relativeComponents: [file.name])
            XCTFail("Readable metadata alone must not validate a truncated audio payload")
        } catch { }
        XCTAssertTrue(try audioFiles(in: library).isEmpty)
    }

    func testSymlinkedDestinationCannotWriteOutsideLibrary() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let source = try await repository.sourceDirectory(connection)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("Sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Album"), withDestinationURL: outside)
        let staged = try stage(original)
        let file = RemoteFile(id: "/song", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        do {
            _ = try await repository.accept(staged, connection: connection, file: file,
                                            relativeComponents: ["Album", file.name])
            XCTFail("A symlinked parent must not be followed")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["Sentinel.txt"])
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testManifestCannotReuseFileThatWasReplacedBySymlink() async throws {
        let original = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let file = RemoteFile(id: "/song", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        let local = try await repository.accept(stage(original), connection: connection, file: file, relativeComponents: [file.name])
        let outside = root.appendingPathComponent("Outside.mp3")
        try original.write(to: outside)
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: outside)
        do {
            let existing = try await self.repository().existingFile(connection: connection, file: file)
            XCTAssertNil(existing, "An outside file must never be reused as an editable library file")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testSymlinkedStagingFileIsRejectedWithoutChangingTarget() async throws {
        let original = try Data(contentsOf: fixture())
        let outside = root.appendingPathComponent("Source.mp3")
        try original.write(to: outside)
        let staged = root.appendingPathComponent("Staging.mp3")
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)
        let file = RemoteFile(id: "/song", name: "Song.mp3", isDirectory: false, size: Int64(original.count))
        do {
            _ = try await repository().accept(staged, connection: connection(), file: file, relativeComponents: [file.name])
            XCTFail("Downloaded input must be a regular file")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertTrue(try audioFiles(in: library).isEmpty)
    }

    @MainActor
    func testRecursiveDownloadReportsLocalFailuresKeepsSuccessAndCleansStaging() async throws {
        let source = try fixture()
        let bytes = try Data(contentsOf: source)
        let good = RemoteFile(id: "good", name: "Good.mp3", isDirectory: false, size: Int64(bytes.count))
        let broken = RemoteFile(id: "broken", name: "Broken.mp3", isDirectory: false, size: Int64(bytes.count))
        let album = RemoteFile(id: "album", name: "Album", isDirectory: true)
        let inaccessible = RemoteFile(id: "inaccessible", name: "Inaccessible", isDirectory: true)
        let unavailable = RemoteFile(id: "unavailable", name: "Unavailable.flac", isDirectory: false, unavailableReason: "No original file")
        let provider = ConnectionDownloadTestProvider(bytes: bytes, directory: ["album": [good, broken, album]], failures: ["broken"])
        let repository = repository()
        let connection = connection()
        let downloads = ConnectionDownloads(repository: repository)
        downloads.start(connection: connection, provider: provider, entries: [album, inaccessible, unavailable], parentNames: [])
        try await waitForCompletion(downloads)
        XCTAssertEqual(downloads.total, 2)
        XCTAssertEqual(downloads.completed, 2)
        XCTAssertEqual(downloads.failures.count, 3)
        XCTAssertTrue(downloads.failures.contains { $0.contains("Unavailable.flac") })
        XCTAssertTrue(downloads.failures.contains { $0.contains("Inaccessible") })
        XCTAssertTrue(downloads.failures.contains { $0.contains("Broken.mp3") })
        let existing = try await repository.existingFile(connection: connection, file: good)
        let local = try XCTUnwrap(existing)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(local.deletingLastPathComponent().lastPathComponent, "Album")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let stages = await provider.destinations
        XCTAssertEqual(stages.count, 2)
        XCTAssertTrue(stages.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try audioFiles(in: library), [local])
    }

    @MainActor
    func testProgressBurstIsCoalescedAndFinalBytesArePublished() async throws {
        let bytes = try Data(contentsOf: fixture())
        let provider = ProgressBurstDownloadProvider(bytes: bytes, callbackCount: 50_000)
        let downloads = ConnectionDownloads(repository: repository())
        let file = RemoteFile(id: "burst", name: "Burst.mp3", isDirectory: false, size: Int64(bytes.count))
        var updates = 0
        let observation = downloads.$receivedBytes.dropFirst().sink { _ in updates += 1 }
        defer { observation.cancel() }

        downloads.start(connection: connection(), provider: provider, entries: [file], parentNames: [])
        try await waitForCompletion(downloads)

        XCTAssertTrue(downloads.failures.isEmpty)
        XCTAssertEqual(downloads.completed, 1)
        XCTAssertEqual(downloads.receivedBytes, Int64(bytes.count))
        XCTAssertEqual(downloads.expectedBytes, Int64(bytes.count))
        XCTAssertLessThan(updates, 100, "Packet callbacks must not flood the UI with progress publications")
    }

    @MainActor
    func testLateProgressFromSameNamedFileCannotOverwriteActiveTransfer() async throws {
        let bytes = try Data(contentsOf: fixture())
        let started = expectation(description: "Second transfer started")
        let provider = ProgressBurstDownloadProvider(bytes: bytes, heldFileID: "second", started: { started.fulfill() })
        let downloads = ConnectionDownloads(repository: repository())
        let files = ["first", "second"].map {
            RemoteFile(id: $0, name: "Same.mp3", isDirectory: false, size: Int64(bytes.count))
        }
        downloads.start(connection: connection(), provider: provider, entries: files, parentNames: [])
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(downloads.isRunning)
        XCTAssertEqual(downloads.completed, 1)
        XCTAssertEqual(downloads.receivedBytes, 100)
        XCTAssertNil(downloads.expectedBytes)

        await provider.release()
        try await waitForCompletion(downloads)
        XCTAssertTrue(downloads.failures.isEmpty)
        XCTAssertEqual(downloads.completed, 2)
        XCTAssertEqual(downloads.receivedBytes, Int64(bytes.count))
        XCTAssertEqual(downloads.expectedBytes, Int64(bytes.count))
    }

    @MainActor
    func testCancellationRemovesPartialDownloadAndCreatesNoManifestEntry() async throws {
        let bytes = try Data(contentsOf: fixture())
        let started = expectation(description: "Partial download written")
        let provider = ConnectionDownloadTestProvider(bytes: bytes, stall: true, started: { started.fulfill() })
        let repository = repository()
        let downloads = ConnectionDownloads(repository: repository)
        let connection = connection()
        let file = RemoteFile(id: "cancelled", name: "Cancelled.mp3", isDirectory: false, size: Int64(bytes.count))
        downloads.start(connection: connection, provider: provider, entries: [file], parentNames: [])
        await fulfillment(of: [started], timeout: 5)
        downloads.cancel()
        try await waitForCompletion(downloads)
        XCTAssertEqual(downloads.completed, 0)
        XCTAssertEqual(downloads.receivedBytes, 100)
        XCTAssertEqual(downloads.expectedBytes, Int64(bytes.count))
        XCTAssertNotNil(downloads.summary)
        let stages = await provider.destinations
        XCTAssertEqual(stages.count, 1)
        XCTAssertTrue(stages.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let existing = try await repository.existingFile(connection: connection, file: file)
        XCTAssertNil(existing)
        XCTAssertTrue(try audioFiles(in: library).isEmpty)
    }

    func testDeletionLeaseExcludesWritersAndIsScopedToTheActualLibraryRoot() throws {
        let access = LocalLibraryAccess.shared
        let firstWriter = try access.acquire(library)
        let secondWriter = try access.acquire(library)
        XCTAssertThrowsError(try access.acquire(library, deleting: true))
        firstWriter.release()
        XCTAssertThrowsError(try access.acquire(library, deleting: true), "Every active writer must finish")
        secondWriter.release()

        let deletion = try access.acquire(library, deleting: true)
        XCTAssertThrowsError(try access.acquire(library))
        XCTAssertThrowsError(try access.acquire(library, deleting: true))
        let unrelated = try access.acquire(root.appendingPathComponent("Another Music"), deleting: true)
        unrelated.release()
        deletion.release()
        deletion.release()
        let reopened = try access.acquire(library)
        reopened.release()
    }

    @MainActor
    func testActiveDownloadBlocksDeletionUntilCancellationFinishes() async throws {
        let bytes = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let existing = RemoteFile(id: "/existing", name: "Existing.mp3", isDirectory: false, size: Int64(bytes.count))
        let local = try await repository.accept(stage(bytes), connection: connection, file: existing,
                                                relativeComponents: [existing.name])
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state, libraryDirectory: library)
        let model = AppModel(fileStore: store)
        await model.load()
        let started = expectation(description: "Download started")
        let provider = ConnectionDownloadTestProvider(bytes: bytes, stall: true) { started.fulfill() }
        let downloading = RemoteFile(id: "/pending", name: "Pending.mp3", isDirectory: false, size: Int64(bytes.count))
        let downloads = ConnectionDownloads(repository: repository)
        downloads.start(connection: connection, provider: provider, entries: [downloading], parentNames: [])
        await fulfillment(of: [started], timeout: 5)

        model.prepareDeletion(urls: [local])

        XCTAssertNil(model.deletionPlan)
        XCTAssertFalse(model.isPreparingDeletion)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        downloads.cancel()
        try await waitForCompletion(downloads)
        model.prepareDeletion(urls: [local])
        try await waitForDeletionPreview(model)
        XCTAssertNotNil(model.deletionPlan, "Finished cancellation must release the download lease")
        model.cancelDeletion()
    }

    @MainActor
    func testDeletionConfirmationBlocksDownloadsAndWiFiAcceptanceUntilCancelled() async throws {
        let bytes = try Data(contentsOf: fixture())
        let repository = repository()
        let connection = connection()
        let existing = RemoteFile(id: "/existing", name: "Existing.mp3", isDirectory: false, size: Int64(bytes.count))
        let local = try await repository.accept(stage(bytes), connection: connection, file: existing,
                                                relativeComponents: [existing.name])
        let store = AudioFileStore(codec: NativeMetadataCodec(), storageDirectory: state, libraryDirectory: library)
        let model = AppModel(fileStore: store)
        await model.load()
        model.prepareDeletion(urls: [local])
        try await waitForDeletionPreview(model)
        let provider = ConnectionDownloadTestProvider(bytes: bytes)
        let incoming = RemoteFile(id: "/new", name: "New.mp3", isDirectory: false, size: Int64(bytes.count))
        let downloads = ConnectionDownloads(repository: repository)

        downloads.start(connection: connection, provider: provider, entries: [incoming], parentNames: [])

        XCTAssertFalse(downloads.isRunning)
        XCTAssertFalse(downloads.failures.isEmpty)
        let attemptedDestinations = await provider.destinations
        XCTAssertTrue(attemptedDestinations.isEmpty, "An unconfirmed deletion must prevent a new transfer from starting")
        let wifiStage = try stage(bytes)
        do {
            _ = try await repository.acceptWiFi(wifiStage, relativePath: "WiFi.mp3", expectedSize: Int64(bytes.count))
            XCTFail("WiFi acceptance must use the same deletion gate")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wifiStage.path))
        XCTAssertEqual(try audioFiles(in: library), [local])

        model.cancelDeletion()
        downloads.start(connection: connection, provider: provider, entries: [incoming], parentNames: [])
        try await waitForCompletion(downloads)
        XCTAssertTrue(downloads.failures.isEmpty)
        XCTAssertEqual(downloads.completed, 1)
        let completedDestinations = await provider.destinations
        XCTAssertEqual(completedDestinations.count, 1)
        XCTAssertEqual(try audioFiles(in: library).count, 2)
    }

    @MainActor
    private func waitForDeletionPreview(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isPreparingDeletion, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.deletionPlan, model.notice ?? "No deletion preview")
    }

    private func repository() -> LocalDownloadRepository {
        LocalDownloadRepository(libraryDirectory: library, stateDirectory: state)
    }

    private func connection() -> RemoteConnection {
        RemoteConnection(kind: .webDAV, name: "Test Server", address: "https://private-server.example/music", username: "private-user")
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp3", subdirectory: "Fixtures"))
    }

    private func stage(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".mp3")
        try data.write(to: url)
        return url
    }

    private func audioFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            ["mp3", "flac", "m4a"].contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    }

    @MainActor
    private func waitForCompletion(_ downloads: ConnectionDownloads) async throws {
        let deadline = Date().addingTimeInterval(5)
        while downloads.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(downloads.isRunning, "Downloads did not finish")
        if downloads.isRunning { downloads.cancel() }
    }
}

private actor ProgressBurstDownloadProvider: RemoteFileProvider {
    let bytes: Data
    let callbackCount: Int
    let heldFileID: String?
    let started: @Sendable () -> Void
    private var previousProgress: (@Sendable (Int64, Int64?) -> Void)?
    private var released = false

    init(bytes: Data, callbackCount: Int = 0, heldFileID: String? = nil,
         started: @escaping @Sendable () -> Void = { }) {
        self.bytes = bytes
        self.callbackCount = callbackCount
        self.heldFileID = heldFileID
        self.started = started
    }

    func release() { released = true }
    func listDirectory(path: String) async throws -> [RemoteFile] { [] }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        if file.id == heldFileID {
            progress(100, nil)
            // Deliberately deliver the previous file's callback after this one
            // starts; display-name based filtering cannot distinguish them.
            previousProgress?(Int64.max, Int64.max)
            started()
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        for index in 0..<callbackCount {
            progress(Int64(index % bytes.count), Int64(bytes.count))
        }
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
        previousProgress = progress
    }
}

private actor ConnectionDownloadTestProvider: RemoteFileProvider {
    let bytes: Data
    let directory: [String: [RemoteFile]]
    let failures: Set<String>
    let stall: Bool
    let started: @Sendable () -> Void
    private(set) var destinations: [URL] = []

    init(bytes: Data, directory: [String: [RemoteFile]] = [:], failures: Set<String> = [], stall: Bool = false,
         started: @escaping @Sendable () -> Void = { }) {
        self.bytes = bytes; self.directory = directory; self.failures = failures; self.stall = stall; self.started = started
    }

    func listDirectory(path: String) async throws -> [RemoteFile] {
        guard let files = directory[path] else { throw MusTagError.message("Directory could not be read") }
        return files
    }

    func download(_ file: RemoteFile, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        destinations.append(destination)
        if stall || failures.contains(file.id) {
            try Data(bytes.prefix(100)).write(to: destination)
            progress(100, Int64(bytes.count))
            started()
            if failures.contains(file.id) { throw MusTagError.message("Transfer interrupted") }
            while true { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}
