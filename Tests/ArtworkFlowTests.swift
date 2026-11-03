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
        let model = AppModel(fileStore: store, recognition: recognition, coverArt: CoverArtService(session: session))
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
