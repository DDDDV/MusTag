import Foundation
import Network
import XCTest
@testable import MusTag

final class WiFiImportTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("Music", isDirectory: true) }
    private var state: URL { root.appendingPathComponent("State", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WiFiImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testParserAcceptsOnlyAuthenticatedAudioUploadAndPreservesFolderPath() throws {
        var components = URLComponents()
        components.path = "/upload"
        components.queryItems = [URLQueryItem(name: "key", value: "secret"), URLQueryItem(name: "path", value: "专辑/Disc 1/01. Song.FLAC")]
        let header = "POST \(components.string!) HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12345"
        let request = try WiFiUploadRequest.parse(Data(header.utf8), token: "secret")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.relativePath, "专辑/Disc 1/01. Song.FLAC")
        XCTAssertEqual(request.length, 12345)
        let page = try WiFiUploadRequest.parse(Data("GET /?key=secret HTTP/1.1\r\nHost: localhost".utf8), token: "secret")
        XCTAssertEqual(page.method, "GET")
        XCTAssertNil(page.relativePath)
    }

    func testParserRejectsMissingDuplicateOrWrongToken() {
        for target in ["/upload?path=Song.mp3", "/upload?key=wrong&path=Song.mp3",
                       "/upload?key=secret&key=secret&path=Song.mp3", "/upload?key=&path=Song.mp3"] {
            XCTAssertThrowsError(try WiFiUploadRequest.parse(
                Data("POST \(target) HTTP/1.1\r\nContent-Length: 10".utf8), token: "secret"), target)
        }
    }

    func testParserRejectsTraversalAbsolutePathsAndAmbiguousBodies() {
        for path in ["../Song.mp3", "/tmp/Song.mp3", "Album/../../Song.mp3", "Album\\Song.mp3",
                     "Album/\u{0000}Song.mp3", "Album/./Song.mp3", "notes.txt"] {
            var components = URLComponents()
            components.path = "/upload"
            components.queryItems = [URLQueryItem(name: "key", value: "secret"), URLQueryItem(name: "path", value: path)]
            XCTAssertThrowsError(try WiFiUploadRequest.parse(
                Data("POST \(components.string!) HTTP/1.1\r\nContent-Length: 10".utf8), token: "secret"), path)
        }
        for headers in ["Content-Length: -1", "Content-Length: 0", "Content-Length: 999999999999999999999999",
                        "Content-Length: 10\r\ncontent-length: 10", "Transfer-Encoding: chunked",
                        "Content-Length: 10\r\nTransfer-Encoding: chunked"] {
            XCTAssertThrowsError(try WiFiUploadRequest.parse(
                Data("POST /upload?key=secret&path=Song.mp3 HTTP/1.1\r\n\(headers)".utf8), token: "secret"), headers)
        }
        XCTAssertThrowsError(try WiFiUploadRequest.parse(
            Data("POST /upload?key=secret&path=%2e%2e%2fSong.mp3 HTTP/1.1\r\nContent-Length: 10".utf8), token: "secret"))
        XCTAssertThrowsError(try WiFiUploadRequest.parse(
            Data("DELETE /upload?key=secret&path=Song.mp3 HTTP/1.1\r\nContent-Length: 10".utf8), token: "secret"))
    }

    func testRepositoryRejectsCancelledWiFiAcceptanceBeforeAnyLocalMutation() async throws {
        let bytes = try Data(contentsOf: fixture())
        let staged = root.appendingPathComponent("staging.mp3")
        try bytes.write(to: staged)
        let repository = repository()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.acceptWiFi(staged, relativePath: "Cancelled.mp3", expectedSize: Int64(bytes.count))
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled upload must not be accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(audioFiles().isEmpty)
    }

    func testWiFiRepositoryCannotEscapeThroughSymlinkedFolder() async throws {
        let bytes = try Data(contentsOf: fixture())
        let wifi = library.appendingPathComponent("WiFi", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: wifi, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: wifi.appendingPathComponent("Album"), withDestinationURL: outside)
        let staged = root.appendingPathComponent("staging.mp3")
        try bytes.write(to: staged)
        do {
            _ = try await repository().acceptWiFi(staged, relativePath: "Album/Escape.mp3", expectedSize: Int64(bytes.count))
            XCTFail("Symlinked folders must not be followed")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testRealHTTPUploadsCompleteAudioLocallyAndPreservesSourceAndSameNamedFiles() async throws {
        let source = try fixture()
        let bytes = try Data(contentsOf: source)
        let running = try await startServer()
        defer { running.server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }

        let (page, pageResponse) = try await session.data(for: request(running, path: nil))
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("MusTag"))
        let relative = "专辑/Disc 1/Original.mp3"
        var upload = request(running, path: relative)
        upload.httpBody = bytes
        let (_, response) = try await session.data(for: upload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let local = try XCTUnwrap(running.events.imported.first)
        XCTAssertEqual(local, library.appendingPathComponent("WiFi/" + relative))
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)

        var tags = try NativeMetadataCodec().read(from: local).tags
        tags.title = "Local edit must survive another upload"
        try NativeMetadataCodec().write(tags, to: local)
        let edited = try Data(contentsOf: local)
        let (_, secondResponse) = try await session.data(for: upload)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        let imported = running.events.imported
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[1].lastPathComponent, "Original (2).mp3")
        XCTAssertEqual(try Data(contentsOf: imported[1]), bytes)
        XCTAssertEqual(try Data(contentsOf: local), edited)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(running.events.failures.isEmpty)
    }

    func testRealHTTPRejectsWrongTokenAndCorruptAudioWithoutLeavingFiles() async throws {
        let bytes = try Data(contentsOf: fixture())
        let initialStaging = wifiStagingFiles()
        let running = try await startServer()
        defer { running.server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        var invalidToken = request(running, path: "WrongToken.mp3", token: "wrong")
        invalidToken.httpBody = bytes
        let (_, denied) = try await session.data(for: invalidToken)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 400)
        var corrupt = request(running, path: "Corrupt.mp3")
        corrupt.httpBody = Data("<html>This is not audio</html>".utf8)
        let (_, rejected) = try await session.data(for: corrupt)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        try await waitUntil("Failed upload staging files were not cleaned") { self.wifiStagingFiles().subtracting(initialStaging).isEmpty }
        XCTAssertTrue(audioFiles().isEmpty)
        XCTAssertTrue(running.events.imported.isEmpty)
    }

    func testDisconnectedPartialHTTPUploadIsRemoved() async throws {
        let bytes = try Data(contentsOf: fixture())
        let initialStaging = wifiStagingFiles()
        let running = try await startServer()
        defer { running.server.stop() }
        let client = WiFiTestTCPClient(port: running.port)
        defer { client.cancel() }
        try await client.connect()
        let head = uploadHeader(running, path: "Partial.mp3", length: bytes.count)
        try await client.send(head + bytes.prefix(100), finish: true)
        do { _ = try await client.readToEnd() }
        catch WiFiTestTCPError.timedOut { XCTFail("Server did not close an incomplete upload") }
        catch { /* A reset is also a valid response to an incomplete request. */ }
        try await waitUntil("Partial upload staging files were not cleaned") { self.wifiStagingFiles().subtracting(initialStaging).isEmpty }
        XCTAssertTrue(audioFiles().isEmpty)
        XCTAssertTrue(running.events.imported.isEmpty)
    }

    func testStoppingServerCancelsInFlightUploadAndRemovesStaging() async throws {
        let bytes = try Data(contentsOf: fixture())
        let initialStaging = wifiStagingFiles()
        let running = try await startServer()
        defer { running.server.stop() }
        let client = WiFiTestTCPClient(port: running.port)
        defer { client.cancel() }
        try await client.connect()
        try await client.send(uploadHeader(running, path: "Interrupted.mp3", length: bytes.count) + bytes.prefix(100))
        try await waitUntil("Server never began staging the upload") { !self.wifiStagingFiles().subtracting(initialStaging).isEmpty }
        running.server.stop()
        try await waitUntil("Stopped server left a staging file") { self.wifiStagingFiles().subtracting(initialStaging).isEmpty }
        XCTAssertTrue(audioFiles().isEmpty)
        XCTAssertTrue(running.events.imported.isEmpty)
    }

    private func startServer() async throws -> WiFiTestRunningServer {
        let ready = expectation(description: "WiFi server ready")
        let events = WiFiTestEvents()
        let server = try WiFiImportServer(port: 0, repository: repository()) { event in
            if events.record(event) { ready.fulfill() }
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        guard let started = events.ready else {
            server.stop()
            throw MusTagError.message("WiFi test listener failed: " + events.failures.joined(separator: "; "))
        }
        return WiFiTestRunningServer(server: server, port: started.0, token: started.1, events: events)
    }

    private func repository() -> LocalDownloadRepository {
        LocalDownloadRepository(libraryDirectory: library, stateDirectory: state)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp3", subdirectory: "Fixtures"))
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }

    private func request(_ running: WiFiTestRunningServer, path: String?, token: String? = nil) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(running.port)
        components.path = path == nil ? "/" : "/upload"
        components.queryItems = [URLQueryItem(name: "key", value: token ?? running.token)]
        if let path { components.queryItems?.append(URLQueryItem(name: "path", value: path)) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = path == nil ? "GET" : "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func uploadHeader(_ running: WiFiTestRunningServer, path: String, length: Int) -> Data {
        let request = request(running, path: path)
        let url = request.url!
        return Data("POST \(url.path)?\(url.query!) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
    }

    private func audioFiles() -> [URL] {
        let files = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.filter { ["mp3", "flac", "m4a"].contains($0.pathExtension.lowercased()) }
    }

    private func wifiStagingFiles() -> Set<URL> {
        let files = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.lastPathComponent.hasPrefix("MusTag-wifi-") })
    }

    private func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), message)
    }
}

private struct WiFiTestRunningServer {
    let server: WiFiImportServer
    let port: UInt16
    let token: String
    let events: WiFiTestEvents
}

private final class WiFiTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var readyValue: (UInt16, String)?
    private var importedValues: [URL] = []
    private var failureValues: [String] = []
    private var announced = false

    func record(_ event: WiFiImportServer.Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .ready(let port, let token): readyValue = (port, token)
        case .imported(let url): importedValues.append(url); return false
        case .failed(let error): failureValues.append(error)
        }
        guard !announced else { return false }
        announced = true
        return true
    }
    var ready: (UInt16, String)? { lock.lock(); defer { lock.unlock() }; return readyValue }
    var imported: [URL] { lock.lock(); defer { lock.unlock() }; return importedValues }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return failureValues }
}

private enum WiFiTestTCPError: Error { case timedOut, disconnected }

private final class WiFiTestTCPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MusTag.WiFiImportTests.Client")

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    deinit { connection.cancel() }
    func cancel() { connection.cancel() }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = WiFiTestGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(WiFiTestTCPError.disconnected))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [connection] in
                if gate.finish(.failure(WiFiTestTCPError.timedOut)) { connection.cancel() }
            }
        }
    }

    func send(_ data: Data, finish: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: finish ? .finalMessage : .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func readToEnd() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = WiFiTestGate<Data>(continuation)
            receive(gate, accumulated: Data())
            queue.asyncAfter(deadline: .now() + 5) { [connection] in
                if gate.finish(.failure(WiFiTestTCPError.timedOut)) { connection.cancel() }
            }
        }
    }

    private func receive(_ gate: WiFiTestGate<Data>, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, ended, error in
            if let error { gate.finish(.failure(error)); return }
            let combined = accumulated + (data ?? Data())
            if ended { gate.finish(.success(combined)) }
            else { self?.receive(gate, accumulated: combined) }
        }
    }
}

private final class WiFiTestGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}
