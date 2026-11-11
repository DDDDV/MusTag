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
        let size = Int64(bytes.count)
        let provider = ControlledDownloadProvider(bytes: bytes)
        let downloads = ConnectionDownloads(repository: repository())
        let connection = connection()
        let first = RemoteFile(id: "first", name: "Same.mp3", isDirectory: false, size: size)
        let second = RemoteFile(id: "second", name: "Same.mp3", isDirectory: false)
        downloads.start(connection: connection, provider: provider, entries: [first, second, first, second], parentNames: [])
        try await waitUntil("Both same-named files must start") { await provider.startedIDs.count == 2 }
        try await waitUntil("Unknown lengths keep aggregate progress indeterminate") { downloads.receivedBytes == 200 }
        XCTAssertEqual(downloads.total, 2, "Duplicate selections must be downloaded only once")
        XCTAssertNil(downloads.expectedBytes)
        await provider.release("first")
        try await waitUntil("First file is saved while the second stays active") { downloads.completed == 1 }
        await provider.emit("first", bytes: Int64.max, expected: Int64.max)
        await provider.emit("second", bytes: 100, expected: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(downloads.isRunning)
        XCTAssertEqual(downloads.receivedBytes, size + 100)
        XCTAssertNil(downloads.expectedBytes)
        await provider.emit("second", bytes: 125, expected: size)
        try await waitUntil("A discovered length updates the aggregate") {
            downloads.receivedBytes == size + 125 && downloads.expectedBytes == size * 2
        }
        await provider.release("second")
        try await waitForCompletion(downloads)
        XCTAssertTrue(downloads.failures.isEmpty)
        XCTAssertEqual(downloads.completed, 2)
        XCTAssertEqual(downloads.receivedBytes, size * 2)
        XCTAssertEqual(downloads.expectedBytes, size * 2)
        let local = try audioFiles(in: library)
        XCTAssertEqual(Set(local.map(\.lastPathComponent)), ["Same.mp3", "Same (2).mp3"])
        for url in local { XCTAssertEqual(try Data(contentsOf: url), bytes) }

        let nextProvider = ControlledDownloadProvider(bytes: bytes)
        let next = RemoteFile(id: "next", name: "Same.mp3", isDirectory: false, size: size)
        downloads.start(connection: connection, provider: nextProvider, entries: [next], parentNames: [])
        try await waitUntil("The next batch starts") { await nextProvider.startedIDs.count == 1 }
        await provider.emit("first", bytes: Int64.max, expected: Int64.max)
        await provider.emit("second", bytes: Int64.max, expected: Int64.max)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(downloads.total, 1)
        XCTAssertEqual(downloads.completed, 0)
        XCTAssertEqual(downloads.receivedBytes, 100, "Old batches cannot publish into the new batch")
        XCTAssertEqual(downloads.expectedBytes, size)
        await nextProvider.release("next")
        try await waitForCompletion(downloads)
        XCTAssertEqual(downloads.receivedBytes, size)
        XCTAssertTrue(downloads.failures.isEmpty)
    }

    @MainActor
    func testAllConnectionKindsLimitConcurrencyAndRefillAfterOutOfOrderSuccessAndFailure() async throws {
        let bytes = try Data(contentsOf: fixture())
        XCTAssertEqual(ConnectionDownloads.maximumConcurrentDownloads, 3)
        for kind in ConnectionKind.allCases {
            var connection = connection()
            connection.kind = kind
            let repository = repository()
            let downloads = ConnectionDownloads(repository: repository)
            let provider = ControlledDownloadProvider(bytes: bytes, failures: ["1"])
            let files = (0..<6).map {
                RemoteFile(id: String($0), name: "Track\($0).mp3", isDirectory: false, size: Int64(bytes.count))
            }
            downloads.start(connection: connection, provider: provider, entries: files, parentNames: [])
            try await waitUntil("\(kind) must start three overlapping downloads") { await provider.startedIDs.count == 3 }
            let initial = await provider.activeIDs
            XCTAssertEqual(initial, ["0", "1", "2"])
            XCTAssertEqual(downloads.activeCount, 3)
            XCTAssertEqual(downloads.completed, 0)

            await provider.release("2")
            try await waitUntil("\(kind) refills immediately after an out-of-order success") {
                await provider.startedIDs.count == 4 && downloads.completed == 1
            }
            let afterSuccess = await provider.activeIDs
            XCTAssertEqual(afterSuccess, ["0", "1", "3"])
            await provider.release("1")
            try await waitUntil("\(kind) refills after a failed file") {
                await provider.startedIDs.count == 5 && downloads.completed == 2
            }
            XCTAssertEqual(downloads.failures.count, 1)
            await provider.release("4")
            try await waitUntil("\(kind) keeps filling available slots") {
                await provider.startedIDs.count == 6 && downloads.completed == 3
            }
            await provider.release("5")
            await provider.release("0")
            await provider.release("3")
            try await waitForCompletion(downloads)
            let peak = await provider.peakActiveCount
            let started = await provider.startedIDs
            let stages = await provider.destinations
            XCTAssertEqual(peak, 3, "\(kind) must never exceed the shared concurrency limit")
            XCTAssertEqual(Set(started), Set(files.map(\.id)))
            XCTAssertEqual(downloads.completed, 6)
            XCTAssertEqual(downloads.activeCount, 0)
            XCTAssertEqual(downloads.failures.count, 1)
            XCTAssertTrue(downloads.failures[0].contains("Track1.mp3"))
            XCTAssertTrue(stages.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            let source = try await repository.sourceDirectory(connection)
            XCTAssertEqual(try audioFiles(in: source).count, 5)
        }
    }

    @MainActor
    func testConcurrentCancellationDrainsChildrenBeforeReleasingLeaseAndKeepsSavedFiles() async throws {
        let bytes = try Data(contentsOf: fixture())
        let provider = ControlledDownloadProvider(bytes: bytes, holdsCancellationCleanup: true)
        let repository = repository()
        let downloads = ConnectionDownloads(repository: repository)
        let connection = connection()
        let files = (0..<5).map {
            RemoteFile(id: String($0), name: "Track\($0).mp3", isDirectory: false, size: Int64(bytes.count))
        }
        downloads.start(connection: connection, provider: provider, entries: files, parentNames: [])
        try await waitUntil("First three downloads start") { await provider.startedIDs.count == 3 }
        await provider.release("0")
        try await waitUntil("The first file is saved and its slot refilled") {
            await provider.startedIDs.count == 4 && downloads.completed == 1
        }
        downloads.cancel()
        try await waitUntil("Cancellation reaches every in-flight child") { await provider.cancelledIDs.count == 3 }
        XCTAssertTrue(downloads.isRunning, "Cancellation must wait for provider cleanup")
        XCTAssertThrowsError(try LocalLibraryAccess.shared.acquire(library, deleting: true))
        await provider.release("1")
        try await waitUntil("One cancelled child exits") { await provider.activeIDs.count == 2 }
        XCTAssertTrue(downloads.isRunning)
        XCTAssertThrowsError(try LocalLibraryAccess.shared.acquire(library, deleting: true), "Other children still hold the batch lease")
        await provider.release("2")
        await provider.release("3")
        try await waitForCompletion(downloads)
        let started = await provider.startedIDs
        let cancelled = await provider.cancelledIDs
        let stages = await provider.destinations
        XCTAssertEqual(Set(started), ["0", "1", "2", "3"], "Queued files must not start after cancellation")
        XCTAssertEqual(cancelled, ["1", "2", "3"])
        XCTAssertEqual(downloads.completed, 1)
        XCTAssertEqual(downloads.activeCount, 0)
        XCTAssertTrue(downloads.failures.isEmpty)
        XCTAssertTrue(stages.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let existing = try await repository.existingFile(connection: connection, file: files[0])
        let local = try XCTUnwrap(existing)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try audioFiles(in: library), [local])
        let deletion = try LocalLibraryAccess.shared.acquire(library, deleting: true)
        deletion.release()
    }

    @MainActor
    func testExistingFilesCountAsCompletedWithoutInflatingNetworkProgress() async throws {
        let bytes = try Data(contentsOf: fixture())
        let size = Int64(bytes.count)
        let repository = repository()
        let connection = connection()
        let existing = RemoteFile(id: "existing", name: "Existing.mp3", isDirectory: false, size: size)
        let pending = RemoteFile(id: "pending", name: "Pending.mp3", isDirectory: false, size: size)
        let local = try await repository.accept(stage(bytes), connection: connection, file: existing,
                                                relativeComponents: [existing.name])
        let provider = ControlledDownloadProvider(bytes: bytes)
        let downloads = ConnectionDownloads(repository: repository)
        downloads.start(connection: connection, provider: provider, entries: [existing, pending], parentNames: [])
        try await waitUntil("Only the pending file starts") { await provider.startedIDs.count == 1 }
        XCTAssertEqual(downloads.total, 2)
        XCTAssertEqual(downloads.completed, 1)
        XCTAssertEqual(downloads.expectedBytes, size)
        await provider.release("pending")
        try await waitForCompletion(downloads)
        let started = await provider.startedIDs
        XCTAssertEqual(started, ["pending"])
        XCTAssertEqual(downloads.completed, 2)
        XCTAssertEqual(downloads.receivedBytes, size)
        XCTAssertEqual(downloads.expectedBytes, size)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
    }

    func testConcurrentTemporarySpaceReservationAndOverflow() throws {
        let reserve: Int64 = 32 * 1_024 * 1_024
        XCTAssertEqual(try LocalDownloadRepository.requiredCapacity(totalSize: 600, largestFile: 300), reserve + 1_200)
        XCTAssertEqual(try LocalDownloadRepository.requiredCapacity(totalSize: 600, largestFile: 300,
                                                                    concurrentTemporarySize: 600), reserve + 1_500)
        XCTAssertEqual(try LocalDownloadRepository.requiredCapacity(totalSize: -1, largestFile: -1,
                                                                    concurrentTemporarySize: -1), reserve)
        XCTAssertEqual(try LocalDownloadRepository.requiredCapacity(totalSize: Int64.max - reserve, largestFile: 0,
                                                                    concurrentTemporarySize: 0), Int64.max)
        XCTAssertThrowsError(try LocalDownloadRepository.requiredCapacity(totalSize: Int64.max, largestFile: 0))
        XCTAssertThrowsError(try LocalDownloadRepository.requiredCapacity(totalSize: 0, largestFile: Int64.max,
                                                                         concurrentTemporarySize: Int64.max))
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

    @MainActor
    private func waitUntil(_ message: String, condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw MusTagError.message(message)
    }
}

private actor ProgressBurstDownloadProvider: RemoteFileProvider {
    let bytes: Data
    let callbackCount: Int

    init(bytes: Data, callbackCount: Int) {
        self.bytes = bytes
        self.callbackCount = callbackCount
    }

    func listDirectory(path: String) async throws -> [RemoteFile] { [] }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        for index in 0..<callbackCount {
            progress(Int64(index % bytes.count), Int64(bytes.count))
        }
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}

/// Individual continuations let tests choose completion order without relying on
/// task scheduling. Cancellation can deliberately wait for asynchronous cleanup.
private actor ControlledDownloadProvider: RemoteFileProvider {
    let bytes: Data
    let failures: Set<String>
    let holdsCancellationCleanup: Bool
    private(set) var startedIDs: [String] = []
    private(set) var activeIDs: Set<String> = []
    private(set) var cancelledIDs: Set<String> = []
    private(set) var peakActiveCount = 0
    private(set) var destinations: [URL] = []
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private var callbacks: [String: @Sendable (Int64, Int64?) -> Void] = [:]
    private var releasedIDs: Set<String> = []

    init(bytes: Data, failures: Set<String> = [], holdsCancellationCleanup: Bool = false) {
        self.bytes = bytes
        self.failures = failures
        self.holdsCancellationCleanup = holdsCancellationCleanup
    }

    func listDirectory(path: String) async throws -> [RemoteFile] { [] }

    func release(_ id: String) {
        releasedIDs.insert(id)
        waiting.removeValue(forKey: id)?.resume()
    }

    func emit(_ id: String, bytes: Int64, expected: Int64?) { callbacks[id]?(bytes, expected) }

    private func cancel(_ id: String) {
        guard activeIDs.contains(id) else { return }
        cancelledIDs.insert(id)
        if !holdsCancellationCleanup { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        startedIDs.append(file.id)
        activeIDs.insert(file.id)
        peakActiveCount = max(peakActiveCount, activeIDs.count)
        destinations.append(destination)
        callbacks[file.id] = progress
        defer { activeIDs.remove(file.id) }
        try Data(bytes.prefix(100)).write(to: destination)
        progress(100, file.size)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if releasedIDs.contains(file.id) { continuation.resume() }
                else if cancelledIDs.contains(file.id), !holdsCancellationCleanup { continuation.resume(throwing: CancellationError()) }
                else { waiting[file.id] = continuation }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(file.id) }
        }
        if failures.contains(file.id) { throw MusTagError.message("Controlled transfer failure") }
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
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
