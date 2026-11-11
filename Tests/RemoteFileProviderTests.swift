import Foundation
import Network
import XCTest
@testable import MusTag

final class RemoteFileProviderTests: XCTestCase {
    func testDAVRequestURLsHaveSingleSeparatorsAndEncodeNamesOnce() throws {
        let address = URL(string: "https://nas.example/dav/")!
        let root = try WebDAVFileProvider.rootURL(address: address, rootPath: "/Music Files/")
        XCTAssertEqual(root.absoluteString, "https://nas.example/dav/Music%20Files/")
        let file = try WebDAVFileProvider.requestURL(root: root, path: "/Album/100% #1.mp3", directory: false)
        XCTAssertEqual(file.absoluteString, "https://nas.example/dav/Music%20Files/Album/100%25%20%231.mp3")
        let folder = try WebDAVFileProvider.requestURL(root: root, path: "/Album", directory: true)
        XCTAssertEqual(folder.absoluteString, "https://nas.example/dav/Music%20Files/Album/")
        XCTAssertThrowsError(try WebDAVFileProvider.requestURL(root: root, path: "/../outside", directory: false))
    }

    func testDAVListingKeepsOnlyImmediateChildrenInsideConfiguredRoot() throws {
        let root = URL(string: "https://nas.example/dav/Music/")!
        let data = Data("""
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/Music/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/Music/Album/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/Music/A%20B.mp3</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>https://other.example/dav/Music/leak.mp3</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/Music/Album/nested.mp3</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/Music/a%2Fb.mp3</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/Music/no-access.mp3</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let files = try WebDAVFileProvider.parseListing(data, requestURL: root, rootURL: root)
        XCTAssertEqual(files.map(\.id), ["/Album", "/A B.mp3"])
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[1].size, 42)
    }

    func testDAVRejectsEntityDefinitionsAndMalformedResponses() {
        let root = URL(string: "https://example.com/")!
        XCTAssertThrowsError(try WebDAVFileProvider.parseListing(Data("<!DOCTYPE x><x/>".utf8), requestURL: root, rootURL: root))
        XCTAssertThrowsError(try WebDAVFileProvider.parseListing(Data("<html/>".utf8), requestURL: root, rootURL: root))
    }

    func testFTPListingPreservesNamesAndSkipsTraversalAndSymlinks() {
        let data = Data("type=file;size=42;modify=20260102123456; A  B.mp3\r\ntype=dir; Album\r\ntype=pdir; ..\r\ntype=file; bad/name.mp3\r\ntype=OS.unix=slink; link.mp3\r\n".utf8)
        let files = FTPListingParser.parseMLSD(data)
        XCTAssertEqual(files.map(\.name), ["A  B.mp3", "Album"])
        XCTAssertEqual(files.first?.size, 42)
        XCTAssertNotNil(files.first?.modifiedAt)
        let unix = Data("-rw-r--r-- 1 user staff 42 Jan 2 2026 A  B.mp3\r\ndrwxr-xr-x 1 user staff 0 Jan 2 12:34 Album\r\nlrwxrwxrwx 1 user staff 1 Jan 2 2026 link -> /outside\r\n".utf8)
        XCTAssertEqual(FTPListingParser.parseLIST(unix).map(\.name), ["A  B.mp3", "Album"])
    }

    func testPassivePortsRejectMalformedOrOutOfRangeEndpoints() {
        XCTAssertEqual(FTPPassiveReply.epsvPort("229 Entering Extended Passive Mode (|||2121|)"), 2121)
        XCTAssertEqual(FTPPassiveReply.pasvPort("227 Passive (192,0,2,1,8,73)"), 2121)
        XCTAssertNil(FTPPassiveReply.epsvPort("229 (|||65536|)"))
        XCTAssertNil(FTPPassiveReply.epsvPort("229 (|2121|)"))
        XCTAssertNil(FTPPassiveReply.pasvPort("227 (192,0,2,1,300,1)"))
    }

    func testConfigurationRejectsCleartextWithoutConsentAndEmbeddedCredentials() throws {
        var config = RemoteConnection(kind: .ftp, name: "FTP", address: "ftp://localhost", username: "user")
        XCTAssertThrowsError(try FTPFileProvider(connection: config, password: "p"))
        config.allowsInsecureConnection = true
        config.username = "user\r\nDELE track.mp3"
        XCTAssertThrowsError(try FTPFileProvider(connection: config, password: "p"))
        config = RemoteConnection(kind: .webDAV, name: "DAV", address: "http://localhost", username: "user")
        XCTAssertThrowsError(try WebDAVFileProvider(connection: config, password: "p"))
        config.address = "https://user:secret@localhost/"
        XCTAssertThrowsError(try WebDAVFileProvider(connection: config, password: "p"))
    }

    func testSMBMapsConfiguredShareAndRootWithoutEscaping() throws {
        let config = RemoteConnection(kind: .smb, name: "NAS", address: "smb://localhost:1445/Music", username: "user", rootPath: "/Library")
        let provider = try SMBFileProvider(connection: config, password: "p")
        let target = try provider.location(for: "/Album/A B.mp3")
        XCTAssertEqual(target.share, "Music")
        XCTAssertEqual(target.path, "Library\\Album\\A B.mp3")
        XCTAssertThrowsError(try provider.location(for: "/../other.mp3"))
        XCTAssertThrowsError(try provider.location(for: "/Album\\other.mp3"))
        let browse = try SMBFileProvider(connection: RemoteConnection(kind: .smb, name: "NAS", address: "localhost", username: ""), password: "")
        XCTAssertNil(try browse.location(for: "/").share)
        XCTAssertEqual(try browse.location(for: "/Music/track.mp3").share, "Music")
    }

    func testFTPReallyListsAndDownloadsThroughControlAndPassiveSockets() async throws {
        let server = try await RemoteProtocolTestServer.start(mode: .ftp)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = RemoteConnection(kind: .ftp, name: "FTP", address: "ftp://127.0.0.1:\(server.port)/Music", username: "user")
        config.allowsInsecureConnection = true
        let provider = try FTPFileProvider(connection: config, password: "password")
        let files = try await provider.listDirectory(path: "/")
        XCTAssertEqual(files.map(\.id), ["/track.mp3"])
        let target = directory.appendingPathComponent("track.mp3")
        try await provider.download(XCTUnwrap(files.first), to: target) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: target), RemoteProtocolTestServer.audio)
        await provider.disconnect()
    }

    func testFTPFailedCompletionRemovesPartialDownload() async throws {
        let server = try await RemoteProtocolTestServer.start(mode: .ftpFailure)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = RemoteConnection(kind: .ftp, name: "FTP", address: "ftp://127.0.0.1:\(server.port)", username: "user")
        config.allowsInsecureConnection = true
        let provider = try FTPFileProvider(connection: config, password: "password")
        do {
            try await provider.download(RemoteFile(id: "/track.mp3", name: "track.mp3", isDirectory: false),
                                        to: directory.appendingPathComponent("track.mp3")) { _, _ in }
            XCTFail("An unsuccessful completion reply must reject the download")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        await provider.disconnect()
    }

    func testFTPCancellationClosesWaitingDataSocketAndRemovesStage() async throws {
        let server = try await RemoteProtocolTestServer.start(mode: .ftpStall)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = RemoteConnection(kind: .ftp, name: "FTP", address: "ftp://127.0.0.1:\(server.port)", username: "user")
        config.allowsInsecureConnection = true
        let provider = try FTPFileProvider(connection: config, password: "password")
        let operation = Task {
            try await provider.download(RemoteFile(id: "/track.mp3", name: "track.mp3", isDirectory: false),
                                        to: directory.appendingPathComponent("track.mp3")) { _, _ in }
        }
        await fulfillment(of: [server.downloadStarted], timeout: 5)
        operation.cancel()
        do { try await operation.value; XCTFail("A cancelled transfer cannot complete") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        await provider.disconnect()
    }

    func testDAVReallyDownloadsAndRejectsRedirects() async throws {
        let server = try await RemoteProtocolTestServer.start(mode: .http)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = RemoteConnection(kind: .webDAV, name: "DAV", address: "http://127.0.0.1:\(server.port)/dav", username: "user")
        config.allowsInsecureConnection = true
        let provider = try WebDAVFileProvider(connection: config, password: "password")
        let target = directory.appendingPathComponent("track.mp3")
        let networkProgress = expectation(description: "Progress arrives during HTTP transfer before local commit")
        try await provider.download(RemoteFile(id: "/track.mp3", name: "track.mp3", isDirectory: false), to: target) { bytes, total in
            if bytes == Int64(RemoteProtocolTestServer.audio.count), total == bytes,
               !FileManager.default.fileExists(atPath: target.path) { networkProgress.fulfill() }
        }
        await fulfillment(of: [networkProgress], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: target), RemoteProtocolTestServer.audio)
        do {
            try await provider.download(RemoteFile(id: "/redirect.mp3", name: "redirect.mp3", isDirectory: false),
                                        to: directory.appendingPathComponent("redirect.mp3")) { _, _ in }
            XCTFail("Redirects must not be followed")
        } catch { }
        await fulfillment(of: [server.redirectRequested], timeout: 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["track.mp3"])
        await provider.disconnect()
    }

    func testDAVTaskCancellationAndDisconnectCloseStalledDownloads() async throws {
        for cancelTask in [true, false] {
            let server = try await RemoteProtocolTestServer.start(mode: .httpStall)
            defer { server.stop() }
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var config = RemoteConnection(kind: .webDAV, name: "DAV", address: "http://127.0.0.1:\(server.port)/dav", username: "user")
            config.allowsInsecureConnection = true
            let provider = try WebDAVFileProvider(connection: config, password: "password")
            let operation = Task {
                try await provider.download(RemoteFile(id: "/stall.mp3", name: "stall.mp3", isDirectory: false),
                                            to: directory.appendingPathComponent("stall.mp3")) { _, _ in }
            }
            await fulfillment(of: [server.downloadStarted], timeout: 5)
            if cancelTask { operation.cancel() } else { await provider.disconnect() }
            do { try await operation.value; XCTFail("An interrupted download cannot complete") } catch { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            await provider.disconnect()
        }
    }

    func testFTPDownloadsThreeFilesConcurrentlyWithIndependentDataSockets() async throws {
        try await assertConcurrentDownloads(kind: .ftp)
    }

    func testDAVDownloadsThreeFilesConcurrentlyWithIndependentOperations() async throws {
        try await assertConcurrentDownloads(kind: .webDAV)
    }

    func testFTPTaskCancellationDoesNotCancelAnotherDownload() async throws {
        try await assertCancellationIsolation(kind: .ftp)
    }

    func testDAVTaskCancellationDoesNotCancelAnotherDownload() async throws {
        try await assertCancellationIsolation(kind: .webDAV)
    }

    func testFTPDisconnectCancelsAllConcurrentDownloads() async throws {
        try await assertConcurrentDisconnect(kind: .ftp)
    }

    func testDAVDisconnectCancelsAllConcurrentDownloads() async throws {
        try await assertConcurrentDisconnect(kind: .webDAV)
    }

    private func assertConcurrentDownloads(kind: ConnectionKind) async throws {
        let server = try await RemoteProtocolTestServer.start(mode: kind == .ftp ? .ftp : .http,
                                                             heldDownloadCount: 3)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try makeProvider(kind: kind, server: server)
        let names = ["first.mp3", "second.mp3", "third.mp3"]
        let operations = names.map { name in
            let file = remoteFile(name)
            return Task {
                try await provider.download(file, to: directory.appendingPathComponent(name)) { _, _ in }
            }
        }
        defer { operations.forEach { $0.cancel() } }
        // The server sends no download body until all three requests arrive. A
        // provider that serializes complete transfers cannot reach this barrier.
        await fulfillment(of: [server.downloadStarted], timeout: 5)
        for name in names { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
        server.releaseDownloads()
        for operation in operations { try await operation.value }
        for name in names {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), RemoteProtocolTestServer.audio(named: name))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(names))
        await provider.disconnect()
    }

    private func assertCancellationIsolation(kind: ConnectionKind) async throws {
        let server = try await RemoteProtocolTestServer.start(mode: kind == .ftp ? .ftp : .http,
                                                             heldDownloadCount: 2)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try makeProvider(kind: kind, server: server)
        let cancelledFile = remoteFile("cancelled.mp3")
        let survivorFile = remoteFile("survivor.mp3")
        let cancelled = Task {
            try await provider.download(cancelledFile, to: directory.appendingPathComponent("cancelled.mp3")) { _, _ in }
        }
        let survivor = Task {
            try await provider.download(survivorFile, to: directory.appendingPathComponent("survivor.mp3")) { _, _ in }
        }
        defer { cancelled.cancel(); survivor.cancel() }
        await fulfillment(of: [server.downloadStarted], timeout: 5)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("The cancelled transfer must fail") } catch { }
        server.releaseDownloads()
        try await survivor.value
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("survivor.mp3")),
                       RemoteProtocolTestServer.audio(named: "survivor.mp3"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["survivor.mp3"])
        await provider.disconnect()
    }

    private func assertConcurrentDisconnect(kind: ConnectionKind) async throws {
        let server = try await RemoteProtocolTestServer.start(mode: kind == .ftp ? .ftp : .http,
                                                             heldDownloadCount: 3)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try makeProvider(kind: kind, server: server)
        let operations = ["first.mp3", "second.mp3", "third.mp3"].map { name in
            let file = remoteFile(name)
            return Task {
                try await provider.download(file, to: directory.appendingPathComponent(name)) { _, _ in }
            }
        }
        defer { operations.forEach { $0.cancel() } }
        await fulfillment(of: [server.downloadStarted], timeout: 5)
        await provider.disconnect()
        for operation in operations {
            do { try await operation.value; XCTFail("Disconnect must interrupt every transfer") } catch { }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func makeProvider(kind: ConnectionKind, server: RemoteProtocolTestServer) throws -> any RemoteFileProvider {
        let scheme = kind == .ftp ? "ftp" : "http"
        var connection = RemoteConnection(kind: kind, name: "Concurrent test", address: "\(scheme)://127.0.0.1:\(server.port)/dav", username: "user")
        connection.allowsInsecureConnection = true
        return try ConnectionProviderFactory.make(connection, password: "password")
    }

    private func remoteFile(_ name: String) -> RemoteFile {
        RemoteFile(id: "/" + name, name: name, isDirectory: false,
                   size: Int64(RemoteProtocolTestServer.audio(named: name).count))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Loopback protocol peer: exercises the real socket/URLSession implementations without external accounts.
private final class RemoteProtocolTestServer: @unchecked Sendable {
    enum Mode {
        case ftp, ftpFailure, ftpStall, http, httpStall
        var isHTTP: Bool { self == .http || self == .httpStall }
    }
    static let audio = Data("ID3-test-audio".utf8)
    static func audio(named name: String) -> Data {
        if name == "track.mp3" { return audio }
        // Different sizes and bytes reveal data connections paired with the
        // wrong control session, even when every transfer reports success.
        return Data(("ID3-" + String(repeating: name, count: 2_000)).utf8)
    }
    let downloadStarted = XCTestExpectation(description: "Download request received")
    let redirectRequested = XCTestExpectation(description: "HTTP redirect response sent")
    let mode: Mode
    let listener: NWListener
    private let queue = DispatchQueue(label: "MusTag.RemoteProtocolTests")
    private var connections: [NWConnection] = []
    private var ftpPeers: [ObjectIdentifier: FTPPeer] = [:]
    private let holdsDownloads: Bool
    private var heldTransfers: [() -> Void] = []
    private final class FTPPeer {
        let control: NWConnection
        var listener: NWListener?
        var passive: NWConnection?
        var pending: Data?
        init(control: NWConnection) { self.control = control }
    }
    var port: UInt16 { listener.port!.rawValue }
    private init(mode: Mode, heldDownloadCount: Int) throws {
        self.mode = mode
        holdsDownloads = heldDownloadCount > 0
        listener = try NWListener(using: .tcp, on: .any)
        downloadStarted.expectedFulfillmentCount = max(1, heldDownloadCount)
    }
    static func start(mode: Mode, heldDownloadCount: Int = 0) async throws -> RemoteProtocolTestServer {
        let server = try RemoteProtocolTestServer(mode: mode, heldDownloadCount: heldDownloadCount)
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { connection.cancel(); return }
            server.connections.append(connection)
            if !server.mode.isHTTP { server.ftpPeers[ObjectIdentifier(connection)] = FTPPeer(control: connection) }
            connection.stateUpdateHandler = { [weak server] state in
                guard case .ready = state, let server else { return }
                connection.stateUpdateHandler = nil
                if !server.mode.isHTTP { server.send("220 Test FTP\r\n", to: connection) }
                server.receive(connection, buffered: Data())
            }
            connection.start(queue: server.queue)
        }
        try await server.start(server.listener)
        return server
    }
    private func start(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in
            listener.cancel()
            ftpPeers.values.forEach { $0.listener?.cancel() }
            connections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
            heldTransfers.removeAll()
            ftpPeers.removeAll()
            connections.removeAll()
        }
    }
    func releaseDownloads() {
        queue.async { [self] in
            let transfers = heldTransfers
            heldTransfers.removeAll()
            transfers.forEach { $0() }
        }
    }
    private func deliverDownload(_ transfer: @escaping () -> Void) {
        if holdsDownloads { heldTransfers.append(transfer) }
        else { transfer() }
    }
    private func send(_ value: String, to connection: NWConnection) {
        connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in })
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self, error == nil else { return }
            var buffer = buffered; buffer.append(bytes ?? Data())
            if self.mode.isHTTP {
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<range.upperBound], as: UTF8.self)
                    let requestLine = header.components(separatedBy: "\r\n")[0]
                    let fields = requestLine.split(separator: " ")
                    let target = fields.count == 3 ? String(fields[1]) : ""
                    let base = URL(string: "http://127.0.0.1:\(self.port)/")!
                    let path = URL(string: target, relativeTo: base)?.path
                    print("WebDAV loopback request: \(requestLine)")
                    if self.mode == .httpStall, path == "/dav/stall.mp3" {
                        self.send("HTTP/1.1 200 OK\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n", to: connection)
                        self.downloadStarted.fulfill()
                        return
                    }
                    let redirect = fields.first == "GET" && path == "/dav/redirect.mp3"
                    if redirect { self.redirectRequested.fulfill() }
                    let isAudio = fields.first == "GET" && path?.hasPrefix("/dav/") == true
                        && path?.hasSuffix(".mp3") == true && !redirect
                    let body = isAudio ? Self.audio(named: (path! as NSString).lastPathComponent) : Data()
                    var response = redirect ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(self.port)/dav/track.mp3\r\n"
                        : (isAudio ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 404 Not Found\r\n")
                    response += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    if isAudio {
                        self.send(response, to: connection)
                        self.downloadStarted.fulfill()
                        self.deliverDownload {
                            connection.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                        }
                    } else {
                        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                    }
                    return
                }
            } else {
                while let end = buffer.range(of: Data("\r\n".utf8)) {
                    let command = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<end.upperBound)
                    self.command(command, control: connection)
                }
            }
            if !done { self.receive(connection, buffered: buffer) }
        }
    }
    private func command(_ text: String, control: NWConnection) {
        guard let peer = ftpPeers[ObjectIdentifier(control)] else { return }
        switch text.split(separator: " ").first {
        case "USER": send("331 Password required\r\n", to: control)
        case "PASS": send("230 Logged in\r\n", to: control)
        case "TYPE", "OPTS": send("200 OK\r\n", to: control)
        case "EPSV": openPassiveListener(for: peer)
        case "MLSD":
            send("150 Opening data\r\n", to: control)
            peer.pending = Data("type=file;size=\(Self.audio.count); track.mp3\r\n".utf8)
            flushData(peer)
        case "RETR":
            send("150 Opening data\r\n", to: control)
            downloadStarted.fulfill()
            if mode == .ftpStall { return }
            let path = String(text.dropFirst(5))
            let body = Self.audio(named: (path as NSString).lastPathComponent)
            deliverDownload { [weak self, weak peer] in
                guard let self, let peer else { return }
                peer.pending = body
                self.flushData(peer)
            }
        default: send("502 Unsupported\r\n", to: control)
        }
    }
    private func openPassiveListener(for peer: FTPPeer) {
        do {
            peer.listener?.cancel()
            let listener = try NWListener(using: .tcp, on: .any)
            peer.listener = listener
            listener.newConnectionHandler = { [weak self, weak peer] connection in
                guard let self, let peer else { connection.cancel(); return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { [weak self, weak peer] state in
                    guard case .ready = state, let self, let peer else { return }
                    connection.stateUpdateHandler = nil
                    peer.passive = connection
                    self.flushData(peer)
                }
                connection.start(queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self, weak peer] state in
                guard let self, let peer else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    self.send("229 Passive (|||\(listener.port!.rawValue)|)\r\n", to: peer.control)
                case .failed:
                    listener.stateUpdateHandler = nil
                    self.send("425 Cannot open data connection\r\n", to: peer.control)
                default: break
                }
            }
            listener.start(queue: queue)
        } catch { send("425 Cannot open data connection\r\n", to: peer.control) }
    }
    private func flushData(_ peer: FTPPeer) {
        guard let data = peer.passive, let bytes = peer.pending else { return }
        peer.passive = nil; peer.pending = nil
        let control = peer.control
        data.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.send(self.mode == .ftpFailure ? "426 Transfer failed\r\n" : "226 Transfer complete\r\n", to: control)
        })
    }
}
