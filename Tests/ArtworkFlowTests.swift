import UIKit
import XCTest
@testable import MusTag

final class ArtworkFlowTests: XCTestCase {
    private let recordingID = "10000000-0000-0000-0000-000000000001"
    private let releaseA = "20000000-0000-0000-0000-000000000001"
    private let releaseB = "20000000-0000-0000-0000-000000000002"

    override func tearDown() {
        ArtworkFlowURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testSelectingReleaseAddsTagsAndCoverToDraftWithoutWritingSource() async throws {
        let originalCover = try artwork(color: .red)
        let downloaded = try artwork(color: .blue)
        let context = try await context(originalCover: originalCover)
        defer { context.cleanUp() }
        installResponses { request in
            XCTAssertEqual(request.url?.path, "/release/\(self.releaseA)/front-1200")
            return .init(status: 200, data: downloaded.data)
        }

        context.model.useCandidate(candidate(releaseA), for: context.document.id)
        try await waitUntilIdle(context.model)

        let result = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(result.draft.title, "Selected A")
        XCTAssertEqual(result.draft.album, "Album A")
        XCTAssertEqual(result.draft.genre, context.document.original.genre,
                       "Empty provider fields must keep existing user metadata")
        XCTAssertEqual(result.draftArtwork, downloaded)
        XCTAssertEqual(result.original, context.document.original)
        XCTAssertEqual(result.originalArtwork, originalCover)
        XCTAssertTrue(result.hasChanges)
        XCTAssertTrue(result.hasArtworkChanges)
        XCTAssertNil(context.model.notice)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        let backups = try FileManager.default.contentsOfDirectory(atPath: context.root.appendingPathComponent("State/Backups").path)
        XCTAssertTrue(backups.isEmpty, "Selecting a release must not create a saved-file backup")
    }

    @MainActor
    func testChangingReleaseWithMissingOrFailedCoverRestoresOriginalCover() async throws {
        let originalCover = try artwork(color: .red)
        let firstCover = try artwork(color: .blue)
        for status in [404, 503] {
            let context = try await context(originalCover: originalCover)
            defer { context.cleanUp() }
            var requestedPaths: [String] = []
            installResponses { request in
                let path = try XCTUnwrap(request.url?.path)
                requestedPaths.append(path)
                if path.contains(self.releaseA) {
                    return .init(status: 200, data: firstCover.data)
                }
                return .init(status: status, data: Data())
            }
            context.model.useCandidate(candidate(releaseA), for: context.document.id)
            try await waitUntilIdle(context.model)
            XCTAssertEqual(context.model.document(context.document.id)?.draftArtwork, firstCover)

            context.model.useCandidate(candidate(releaseB), for: context.document.id)
            try await waitUntilIdle(context.model)

            var expectedPaths = ["/release/\(releaseA)/front-1200", "/release/\(releaseB)/front-1200"]
            if status == 404 { expectedPaths.append("/release/\(releaseB)/front") }
            XCTAssertEqual(requestedPaths, expectedPaths,
                           "Only a missing thumbnail may fall back to the same release's original cover")
            let result = try XCTUnwrap(context.model.document(context.document.id))
            XCTAssertEqual(result.draft.title, "Selected B", "HTTP \(status)")
            XCTAssertEqual(result.draft.album, "Album B", "HTTP \(status)")
            XCTAssertEqual(result.draftArtwork, originalCover, "Another release's draft cover must not leak")
            XCTAssertFalse(result.hasArtworkChanges)
            XCTAssertNotNil(context.model.notice)
            XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
        }
    }

    @MainActor
    func testMissingCoverRestoresAbsenceWhenOriginalHadNoCover() async throws {
        let firstCover = try artwork(color: .blue)
        let context = try await context(originalCover: nil)
        defer { context.cleanUp() }
        installResponses { request in
            request.url?.path.contains(self.releaseA) == true
                ? .init(status: 200, data: firstCover.data)
                : .init(status: 404, data: Data())
        }
        context.model.useCandidate(candidate(releaseA), for: context.document.id)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(context.model.document(context.document.id)?.draftArtwork, firstCover)

        context.model.useCandidate(candidate(releaseB), for: context.document.id)
        try await waitUntilIdle(context.model)
        let result = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertNil(result.originalArtwork)
        XCTAssertNil(result.draftArtwork)
        XCTAssertFalse(result.hasArtworkChanges)
        XCTAssertEqual(result.draft.album, "Album B")
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
    }

    @MainActor
    func testCancelledSelectionKeepsPreviousDraftTagsAndCover() async throws {
        let originalCover = try artwork(color: .red)
        let firstCover = try artwork(color: .blue)
        let context = try await context(originalCover: originalCover)
        defer { context.cleanUp() }
        let secondDownloadStarted = expectation(description: "Selected release B cover request started")
        installResponses { request in
            if request.url?.path.contains(self.releaseA) == true {
                return .init(status: 200, data: firstCover.data)
            }
            secondDownloadStarted.fulfill()
            return .init(status: 200, data: Data(), stalls: true)
        }
        context.model.useCandidate(candidate(releaseA), for: context.document.id)
        try await waitUntilIdle(context.model)
        let previous = try XCTUnwrap(context.model.document(context.document.id))

        context.model.useCandidate(candidate(releaseB), for: context.document.id)
        await fulfillment(of: [secondDownloadStarted], timeout: 3)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        let result = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(result.draft, previous.draft)
        XCTAssertEqual(result.draftArtwork, previous.draftArtwork)
        XCTAssertEqual(result.originalArtwork, originalCover)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
    }

    @MainActor
    func testResetCoverKeepsTextAndDiscardRestoresBoth() async throws {
        let originalCover = try artwork(color: .red)
        let downloaded = try artwork(color: .blue)
        let context = try await context(originalCover: originalCover)
        defer { context.cleanUp() }
        installResponses { _ in .init(status: 200, data: downloaded.data) }
        context.model.useCandidate(candidate(releaseA), for: context.document.id)
        try await waitUntilIdle(context.model)
        let selectedTags = try XCTUnwrap(context.model.document(context.document.id)).draft

        context.model.resetArtwork(for: context.document.id)
        let reset = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(reset.draft, selectedTags)
        XCTAssertEqual(reset.draftArtwork, originalCover)
        XCTAssertFalse(reset.hasArtworkChanges)
        XCTAssertTrue(reset.hasChanges)

        context.model.useCandidate(candidate(releaseA), for: context.document.id)
        try await waitUntilIdle(context.model)
        XCTAssertEqual(context.model.document(context.document.id)?.draftArtwork, downloaded)
        context.model.discardChanges(for: context.document.id)
        let discarded = try XCTUnwrap(context.model.document(context.document.id))
        XCTAssertEqual(discarded.draft, context.document.original)
        XCTAssertEqual(discarded.draftArtwork, originalCover)
        XCTAssertFalse(discarded.hasChanges)
        XCTAssertEqual(try Data(contentsOf: context.source), context.originalBytes)
    }

    private func candidate(_ releaseID: String) -> MetadataCandidate {
        MetadataCandidate(id: releaseID, recordingID: recordingID, releaseID: releaseID,
                          tags: AudioTags(title: releaseID == releaseA ? "Selected A" : "Selected B",
                                          artist: "Matched artist"), detail: "MusicBrainz")
    }

    private func installResponses(cover: @escaping (URLRequest) throws -> ArtworkFlowURLProtocol.Response) {
        ArtworkFlowURLProtocol.handler = { request in
            switch request.url?.host {
            case "musicbrainz.org":
                let id = try XCTUnwrap(request.url?.lastPathComponent)
                let body: [String: Any] = ["id": id, "title": id == self.releaseA ? "Album A" : "Album B"]
                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: body))
            case "coverartarchive.org":
                return try cover(request)
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }
    }

    @MainActor
    private func context(originalCover: AudioArtwork?) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.m4a")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "m4a", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: source)
        let codec = NativeMetadataCodec()
        try codec.write(AudioTags(title: "Original title", artist: "Original artist", album: "Original album", genre: "Local genre"), to: source)
        if let originalCover { try codec.writeArtwork(originalCover, to: source) }
        let store = AudioFileStore(codec: codec, storageDirectory: root.appendingPathComponent("State"))
        let imported = try await store.importFiles(from: [source])
        let document = try XCTUnwrap(imported.documents.first, imported.failures.joined(separator: "; "))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recognition = MusicRecognitionService(session: session, minimumMusicBrainzInterval: 0, minimumAcoustIDInterval: 0)
        let model = AppModel(fileStore: store, recognition: recognition, coverArt: CoverArtService(session: session),
                             recognitionProvider: .acoustID)
        model.documents = [document]
        return Context(root: root, source: source, originalBytes: try Data(contentsOf: source), document: document,
                       session: session, model: model)
    }

    @MainActor
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isWorking, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !model.isWorking else {
            model.cancelOperation()
            XCTFail("The selection did not complete before the deadline")
            throw URLError(.timedOut)
        }
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
        let session: URLSession
        let model: AppModel

        func cleanUp() {
            model.cancelOperation()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

final class BatchMatchingFlowTests: XCTestCase {
    override func tearDown() {
        ArtworkFlowURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testBatchAppliesNinetyPercentToDraftAndLeavesLowNoMatchAndUnselectedFilesAlone() async throws {
        let context = try await context([
            Fixture(name: "boundary", score: 0.9),
            Fixture(name: "low", score: 0.8999),
            Fixture(name: "missing", score: nil),
            Fixture(name: "unselected")
        ])
        defer { context.cleanUp() }
        let boundary = try context.document("boundary")
        let low = try context.document("low")
        let missing = try context.document("missing")
        let unselected = try context.document("unselected")
        var previousDraft = low.draft
        previousDraft.title = "My unsaved edit"
        context.model.updateDraft(previousDraft, for: low.id)

        context.model.identify([boundary.id, low.id, missing.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        let matched = try XCTUnwrap(context.model.document(boundary.id))
        XCTAssertEqual(matched.draft.title, "Matched boundary")
        XCTAssertEqual(matched.draft.album, "Matched album")
        XCTAssertEqual(matched.draft.genre, boundary.original.genre, "Empty provider fields keep the previous value")
        XCTAssertEqual(matched.draftArtwork, context.downloadedCover)
        XCTAssertEqual(matched.original, boundary.original)
        XCTAssertNotNil(context.model.appliedCandidateIDs[boundary.id])
        XCTAssertEqual(context.model.document(low.id)?.draft, previousDraft)
        XCTAssertNotNil(context.model.document(low.id)?.error)
        XCTAssertEqual(context.model.document(missing.id)?.draft, missing.draft)
        XCTAssertNotNil(context.model.document(missing.id)?.error)
        XCTAssertEqual(context.model.document(unselected.id)?.draft, unselected.draft)
        XCTAssertNil(context.model.candidates[unselected.id])
        XCTAssertNil(context.model.appliedCandidateIDs[low.id])
        XCTAssertEqual(context.model.completedCount, 3)
        XCTAssertNotNil(context.model.notice)
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first { $0.id == boundary.id }?.draft, matched.draft)
        try await assertSourcesUnchanged(context)
    }

    @MainActor
    func testTiedEditionsUseOriginalAlbumAndUnresolvedTiesKeepExistingDraft() async throws {
        let context = try await context([
            Fixture(name: "preferred", originalAlbum: "Original album", releaseTitles: ["Compilation", "Original album"]),
            Fixture(name: "ambiguous", originalAlbum: "Unknown album", releaseTitles: ["Edition A", "Edition B"])
        ])
        defer { context.cleanUp() }
        let preferred = try context.document("preferred")
        let ambiguous = try context.document("ambiguous")
        var preferredDraft = preferred.draft
        preferredDraft.album = "Compilation"
        context.model.updateDraft(preferredDraft, for: preferred.id)
        var ambiguousDraft = ambiguous.draft
        ambiguousDraft.title = "Keep this edit"
        context.model.updateDraft(ambiguousDraft, for: ambiguous.id)

        context.model.identify([preferred.id, ambiguous.id], automaticallyApply: true)
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(preferred.id)?.draft.album, "Original album",
                       "Tie breaking uses the original file album rather than a pending draft")
        let chosenID = try XCTUnwrap(context.model.appliedCandidateIDs[preferred.id])
        let chosen = try XCTUnwrap(context.model.candidates[preferred.id]?.first { $0.id == chosenID })
        XCTAssertEqual(chosen.tags.album, "Original album")
        XCTAssertEqual(context.model.document(ambiguous.id)?.draft, ambiguousDraft)
        XCTAssertEqual(context.model.document(ambiguous.id)?.draftArtwork, ambiguous.originalArtwork)
        XCTAssertNil(context.model.appliedCandidateIDs[ambiguous.id])
        XCTAssertNotNil(context.model.document(ambiguous.id)?.error)
        XCTAssertEqual(context.model.candidates[ambiguous.id]?.count, 2)
        try await assertSourcesUnchanged(context)
    }

    @MainActor
    func testLookupFailureDoesNotStopBatchAndCoverFailureStillAppliesText() async throws {
        let context = try await context([
            Fixture(name: "failed", lookupFails: true),
            Fixture(name: "cover-failed", coverStatus: 500),
            Fixture(name: "success")
        ])
        defer { context.cleanUp() }
        let failed = try context.document("failed")
        let coverFailed = try context.document("cover-failed")
        let success = try context.document("success")

        context.model.identify(Set(context.model.documents.map(\.id)), automaticallyApply: true)
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(failed.id)?.draft, failed.draft)
        XCTAssertNotNil(context.model.document(failed.id)?.error)
        XCTAssertEqual(context.model.document(coverFailed.id)?.draft.title, "Matched cover-failed")
        XCTAssertEqual(context.model.document(coverFailed.id)?.draftArtwork, coverFailed.originalArtwork)
        XCTAssertNotNil(context.model.appliedCandidateIDs[coverFailed.id])
        XCTAssertEqual(context.model.document(success.id)?.draft.title, "Matched success")
        XCTAssertEqual(context.model.document(success.id)?.draftArtwork, context.downloadedCover)
        XCTAssertEqual(context.model.completedCount, 3)
        XCTAssertNotNil(context.model.notice)
        try await assertSourcesUnchanged(context)
    }

    @MainActor
    func testCancellingLaterFileRetainsCompletedDraftAndPersistsIt() async throws {
        let stalled = expectation(description: "Second file reached cover download")
        let context = try await context([
            Fixture(name: "completed"),
            Fixture(name: "cancelled", stallsCover: true),
            Fixture(name: "pending")
        ], onStalledCover: { stalled.fulfill() })
        defer { context.cleanUp() }
        let completed = try context.document("completed")
        let cancelled = try context.document("cancelled")
        let pending = try context.document("pending")

        context.model.identify(Set(context.model.documents.map(\.id)), automaticallyApply: true)
        await fulfillment(of: [stalled], timeout: 5)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(completed.id)?.draft.title, "Matched completed")
        XCTAssertEqual(context.model.document(cancelled.id)?.draft, cancelled.draft)
        XCTAssertEqual(context.model.document(cancelled.id)?.draftArtwork, cancelled.originalArtwork)
        XCTAssertEqual(context.model.document(pending.id)?.draft, pending.draft)
        XCTAssertNil(context.model.candidates[pending.id])
        XCTAssertNil(context.model.appliedCandidateIDs[cancelled.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first { $0.id == completed.id }?.draft.title, "Matched completed")
        XCTAssertEqual(persisted.documents.first { $0.id == cancelled.id }?.draft, cancelled.draft)
        try await assertSourcesUnchanged(context)
    }

    @MainActor
    func testCancellingFirstFilePersistsTheManualDraftPendingBeforeMatching() async throws {
        let stalled = expectation(description: "First file reached cover download")
        let context = try await context([
            Fixture(name: "cancelled", stallsCover: true)
        ], onStalledCover: { stalled.fulfill() })
        defer { context.cleanUp() }
        let document = try context.document("cancelled")
        var manualDraft = document.draft
        manualDraft.title = "Manual edit pending persistence"
        context.model.updateDraft(manualDraft, for: document.id)

        // Starting immediately cancels updateDraft's scheduled persistence.
        context.model.identify([document.id], automaticallyApply: true)
        await fulfillment(of: [stalled], timeout: 5)
        context.model.cancelOperation()
        try await waitUntilIdle(context.model)

        XCTAssertEqual(context.model.document(document.id)?.draft, manualDraft)
        XCTAssertEqual(context.model.document(document.id)?.draftArtwork, document.originalArtwork)
        XCTAssertNil(context.model.appliedCandidateIDs[document.id])
        let persisted = try await context.store.loadLibrary()
        XCTAssertEqual(persisted.documents.first { $0.id == document.id }?.draft, manualDraft)
        try await assertSourcesUnchanged(context)
    }

    private struct Fixture {
        let name: String
        var score: Double? = 0.96
        var originalAlbum = "Original album"
        var releaseTitles = ["Matched album"]
        var lookupFails = false
        var coverStatus = 200
        var stallsCover = false
    }

    @MainActor
    private func context(_ fixtures: [Fixture], onStalledCover: (() -> Void)? = nil) async throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "m4a", subdirectory: "Fixtures"))
        let originalCover = try artwork(color: .red)
        let downloadedCover = try artwork(color: .blue)
        let codec = NativeMetadataCodec()
        var sources: [URL] = []
        var originalBytes: [URL: Data] = [:]
        for fixture in fixtures {
            let source = root.appendingPathComponent(fixture.name).appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: sample, to: source)
            try codec.write(AudioTags(title: "Original \(fixture.name)", artist: "Original artist",
                                      album: fixture.originalAlbum, genre: "Preserved genre"), to: source)
            try codec.writeArtwork(originalCover, to: source)
            sources.append(source)
            originalBytes[source] = try Data(contentsOf: source)
        }
        let store = AudioFileStore(codec: codec, storageDirectory: root.appendingPathComponent("State"))
        let imported = try await store.importFiles(from: sources)
        XCTAssertTrue(imported.failures.isEmpty, imported.failures.joined(separator: "; "))
        try await store.persistLibrary(AudioLibrary(documents: imported.documents, folders: []))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let recognition = MusicRecognitionService(session: session, minimumMusicBrainzInterval: 0,
                                                   minimumAcoustIDInterval: 0, fingerprintProvider: { url in
            (url.deletingPathExtension().lastPathComponent, 120)
        })
        let model = AppModel(fileStore: store, recognition: recognition, coverArt: CoverArtService(session: session),
                             recognitionProvider: .acoustID)
        await model.load()
        model.apiKey = "fixture-key"
        installResponses(fixtures, cover: downloadedCover, onStalledCover: onStalledCover)
        return Context(root: root, store: store, originalBytes: originalBytes,
                       downloadedCover: downloadedCover, session: session, model: model)
    }

    private func installResponses(_ fixtures: [Fixture], cover: AudioArtwork, onStalledCover: (() -> Void)?) {
        func recordingID(_ index: Int) -> String { String(format: "10000000-0000-0000-0000-%012d", index + 1) }
        func releaseID(_ index: Int, _ edition: Int) -> String { String(format: "20000000-0000-0000-0000-%012d", index * 10 + edition + 1) }
        func json(_ value: [String: Any]) throws -> ArtworkFlowURLProtocol.Response {
            .init(status: 200, data: try JSONSerialization.data(withJSONObject: value))
        }
        ArtworkFlowURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "api.acoustid.org" {
                let body = try XCTUnwrap(Self.requestBody(request))
                let fingerprint = URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "fingerprint" }?.value
                let index = try XCTUnwrap(fixtures.firstIndex { $0.name == fingerprint })
                let fixture = fixtures[index]
                if fixture.lookupFails { return .init(status: 500, data: Data()) }
                guard let score = fixture.score else { return try json(["status": "ok", "results": []]) }
                return try json(["status": "ok", "results": [["score": score,
                    "recordings": [["id": recordingID(index), "title": "Matched \(fixture.name)"]]]]])
            }
            for (index, fixture) in fixtures.enumerated() {
                if url.host == "musicbrainz.org", url.path == "/ws/2/recording/\(recordingID(index))" {
                    let releases = fixture.releaseTitles.enumerated().map { edition, title in
                        ["id": releaseID(index, edition), "title": title]
                    }
                    return try json(["id": recordingID(index), "title": "Matched \(fixture.name)", "releases": releases])
                }
                for (edition, title) in fixture.releaseTitles.enumerated() {
                    let release = releaseID(index, edition)
                    if url.host == "musicbrainz.org", url.path == "/ws/2/release/\(release)" {
                        return try json(["id": release, "title": title])
                    }
                    if url.host == "coverartarchive.org", url.path.hasPrefix("/release/\(release)/") {
                        if fixture.stallsCover {
                            onStalledCover?()
                            return .init(status: 200, data: Data(), stalls: true)
                        }
                        return .init(status: fixture.coverStatus, data: fixture.coverStatus == 200 ? cover.data : Data())
                    }
                }
            }
            XCTFail("Unexpected batch request: \(url.absoluteString)")
            throw URLError(.unsupportedURL)
        }
    }

    private static func requestBody(_ request: URLRequest) -> String? {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) }
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

    @MainActor
    private func assertSourcesUnchanged(_ context: Context, file: StaticString = #filePath, line: UInt = #line) async throws {
        for (url, bytes) in context.originalBytes {
            XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
        }
        let backups = try await context.store.backups()
        XCTAssertTrue(backups.isEmpty, "Auto matching must not save files or create backups", file: file, line: line)
    }

    @MainActor
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(8)
        while model.isWorking, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !model.isWorking else {
            model.cancelOperation()
            XCTFail("Batch matching did not complete before the deadline")
            throw URLError(.timedOut)
        }
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
        let store: AudioFileStore
        let originalBytes: [URL: Data]
        let downloadedCover: AudioArtwork
        let session: URLSession
        let model: AppModel

        func document(_ name: String) throws -> AudioDocument {
            try XCTUnwrap(model.documents.first { $0.url.deletingPathExtension().lastPathComponent == name })
        }

        func cleanUp() {
            model.cancelOperation()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class ArtworkFlowURLProtocol: URLProtocol {
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
            let response = try XCTUnwrap(Self.handler)(request)
            if response.stalls { return }
            let http = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: response.status,
                                                   httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}
