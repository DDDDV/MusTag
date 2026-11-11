import CryptoKit
import Foundation
import XCTest
@testable import MusTag

final class MusicServerConnectionTests: XCTestCase {
    override func tearDown() {
        MusicServerTestURLProtocol.handler = nil
        super.tearDown()
    }

    func testSubsonicAndNavidromeBrowseEveryPageAndDownloadOriginalFilename() async throws {
        for kind in [ConnectionKind.subsonic, .navidrome] {
            let audio = Data("fLaC-original-audio".utf8)
            let log = MusicServerRequestLog()
            MusicServerTestURLProtocol.handler = { request in
                log.append(request)
                let query = Self.query(request)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query["u"], "listener")
                XCTAssertEqual(query["c"], "MusTag")
                XCTAssertNil(query["p"])
                let salt = try XCTUnwrap(query["s"])
                let expectedToken = Insecure.MD5.hash(data: Data(("test-password" + salt).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(query["t"], expectedToken)
                switch request.url?.lastPathComponent {
                case "getAlbumList2.view":
                    XCTAssertEqual(query["type"], "alphabeticalByName")
                    // The server caps pages to one item although the client asks for 500.
                    let albums: [[String: Any]]
                    switch query["offset"] {
                    case "0": albums = [["id": "album / 一", "name": "First"]]
                    case "1": albums = [["id": "album2", "name": "Second"]]
                    case "2": albums = []
                    default: throw MusicServerTestError.unexpectedRequest
                    }
                    return try .subsonic(["albumList2": ["album": albums]])
                case "getAlbum.view":
                    XCTAssertEqual(query["id"], "album / 一")
                    return try .subsonic(["album": ["song": [["id": "song / 一", "title": "Display title",
                        "path": "Artist/01. Original Name.FLAC", "size": audio.count]]]])
                case "getSong.view":
                    XCTAssertEqual(query["id"], "song / 一")
                    return try .subsonic(["song": ["id": "song / 一", "path": "Artist/01. Original Name.FLAC", "size": audio.count]])
                case "download.view":
                    XCTAssertEqual(query["id"], "song / 一")
                    XCTAssertNil(query["maxBitRate"])
                    XCTAssertEqual(query["format"], kind == .navidrome ? "raw" : nil)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
                    return .init(headers: ["Content-Type": "audio/flac", "Content-Length": String(audio.count)], data: audio)
                default:
                    throw MusicServerTestError.unexpectedRequest
                }
            }
            let provider = try provider(kind)
            let albums = try await provider.listDirectory(path: "/")
            XCTAssertEqual(albums.map(\.name), ["First", "Second"])
            let tracks = try await provider.listDirectory(path: albums[0].id)
            let track = try XCTUnwrap(tracks.first)
            XCTAssertEqual(track.name, "01. Original Name.FLAC")
            XCTAssertEqual(track.size, Int64(audio.count))
            XCTAssertTrue(track.isSupportedAudio)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent(track.name)
            try await provider.download(track, to: destination) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: destination), audio)
            XCTAssertEqual(log.requests.filter { $0.url?.lastPathComponent == "getAlbumList2.view" }.count, 3)
            XCTAssertFalse(log.requests.contains { $0.url?.lastPathComponent == "stream.view" })
            await provider.disconnect()
        }
    }

    func testFeiniuUsesHashedLoginPagedCatalogAndUntranscodedMedia() async throws {
        let audio = Data("fLaC-feiniu-original".utf8)
        let log = MusicServerRequestLog()
        MusicServerTestURLProtocol.handler = { request in
            log.append(request)
            let query = Self.query(request)
            if request.url?.path.hasSuffix("/user/password-login") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String])
                XCTAssertEqual(body["username"], "listener")
                XCTAssertEqual(body["password"], SHA256.hash(data: Data("test-password".utf8)).map { String(format: "%02x", $0) }.joined())
                XCTAssertNotNil(body["deviceId"])
                return try .feiniu(["userToken": "private-token"])
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "music-token=private-token")
            switch request.url?.lastPathComponent {
            case "list":
                XCTAssertEqual(request.url?.path, "/prefix/music/api/v1/track/list")
                let tracks: [[String: Any]]
                switch query["page"] {
                case "1": tracks = [
                    ["guid": "song-a", "title": "Wrong display filename", "album": ["guid": "album-a", "name": "Album A"],
                     "audioSpec": ["path": "/Music/真实文件.flac", "size": String(audio.count)]],
                    ["guid": "cue", "isCue": true, "album": ["guid": "album-a", "name": "Album A"],
                     "audioSpec": ["path": "/Music/full-album.flac"]]
                ]
                case "2": tracks = [
                    ["guid": "deleted", "audioFileDeleted": true, "title": "Deleted", "album": ["guid": "album-b", "name": "Album B"]],
                    ["guid": "needs-details", "title": "Display title", "album": ["guid": "album-b", "name": "Album B"]]
                ]
                default: throw MusicServerTestError.unexpectedRequest
                }
                return try .feiniu(["total": 4, "list": tracks])
            case "metadata":
                if query["guid"] == "needs-details" {
                    return try .feiniu(["track": ["guid": "needs-details", "audioSpec": ["path": "/Music/Original.mp3", "size": 42]]])
                }
                XCTAssertEqual(query["guid"], "song-a")
                return try .feiniu(["track": ["guid": "song-a", "audioSpec": ["path": "/Music/真实文件.flac", "size": audio.count]]])
            case "stream":
                XCTAssertEqual(query, ["guid": "song-a"])
                XCTAssertNil(request.url?.query?.range(of: "private-token"))
                return .init(headers: ["Content-Type": "application/octet-stream"], data: audio)
            default: throw MusicServerTestError.unexpectedRequest
            }
        }
        let provider = try provider(.feiniu, address: "https://music.example/prefix/music/")
        let albums = try await provider.listDirectory(path: "/")
        XCTAssertEqual(albums.map(\.name), ["Album A", "Album B"])
        let first = try await provider.listDirectory(path: albums[0].id)
        let second = try await provider.listDirectory(path: albums[1].id)
        XCTAssertEqual(first[0].name, "真实文件.flac")
        XCTAssertFalse(first[1].isSupportedAudio)
        XCTAssertNotNil(first[1].unavailableReason)
        XCTAssertFalse(second[0].isSupportedAudio)
        XCTAssertEqual(second[1].name, "Original.mp3")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(first[0].name)
        try await provider.download(first[0], to: destination) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: destination), audio)
        XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(log.requests.filter { $0.url?.lastPathComponent == "list" }.count, 2)
        XCTAssertTrue(log.requests.allSatisfy { request in
            ["password-login", "list", "metadata", "stream"].contains(request.url?.lastPathComponent ?? "")
        })
        await provider.disconnect()
    }

    func testMissingOriginalFilenameIsVisibleAndDoesNotBlockOtherSongs() async throws {
        MusicServerTestURLProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "getAlbum.view":
                return try .subsonic(["album": ["song": [
                    ["id": "bad", "title": "No original path", "suffix": "mp3"],
                    ["id": "good", "title": "Title", "path": "original.flac", "size": 23]
                ]]])
            case "getSong.view": return .init(status: 503, data: Data())
            default: throw MusicServerTestError.unexpectedRequest
            }
        }
        let provider = try provider(.subsonic)
        let files = try await provider.listDirectory(path: "/subsonic/album/YQ")
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(files[0].isSupportedAudio)
        XCTAssertTrue(files[0].unavailableReason?.contains("503") == true)
        XCTAssertEqual(files[1].name, "original.flac")
        XCTAssertTrue(files[1].isSupportedAudio)
        await provider.disconnect()
    }

    func testSubsonicRepeatedPageFailsInsteadOfLoopingOrReturningPartialCatalog() async throws {
        MusicServerTestURLProtocol.handler = { _ in
            try .subsonic(["albumList2": ["album": [["id": "a", "name": "Repeated"]]]])
        }
        let provider = try provider(.subsonic)
        do {
            _ = try await provider.listDirectory(path: "/")
            XCTFail("Repeated pages must not be accepted")
        } catch MusicServerFailure.repeatedPage { }
        catch { XCTFail("Unexpected error: \(error)") }
        await provider.disconnect()
    }

    func testFeiniuPrematureEmptyPageFailsInsteadOfTruncatingCatalog() async throws {
        MusicServerTestURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "password-login" { return try .feiniu(["userToken": "token"]) }
            if Self.query(request)["page"] == "1" {
                return try .feiniu(["total": 2, "list": [["guid": "one", "audioSpec": ["path": "One.flac"]]]])
            }
            return try .feiniu(["total": 2, "list": []])
        }
        let provider = try provider(.feiniu)
        do {
            _ = try await provider.listDirectory(path: "/")
            XCTFail("Incomplete pages must not be accepted")
        } catch MusicServerFailure.incompletePage { }
        catch { XCTFail("Unexpected error: \(error)") }
        await provider.disconnect()
    }

    func testRepeatedMalformedPageAlsoStopsWithoutIdentifiers() async throws {
        MusicServerTestURLProtocol.handler = { _ in
            try .subsonic(["albumList2": ["album": [["name": "Missing identifier"]]]])
        }
        let provider = try provider(.navidrome)
        do {
            _ = try await provider.listDirectory(path: "/")
            XCTFail("Repeated malformed pages must not create an endless browse")
        } catch MusicServerFailure.repeatedPage { }
        catch { XCTFail("Unexpected error: \(error)") }
        await provider.disconnect()
    }

    func testHTTPRequiresExplicitOptInAndEmbeddedCredentialsAreRejected() throws {
        XCTAssertThrowsError(try provider(.subsonic, address: "http://music.example")) { error in
            guard case MusicServerFailure.insecureHTTP = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try provider(.subsonic, address: "https://user:secret@music.example"))
        XCTAssertNoThrow(try provider(.feiniu, address: "http://music.example:5666", allowsHTTP: true))
        XCTAssertNoThrow(try provider(.navidrome, address: "music.example/library/rest/"))
    }

    func testRedirectPolicyNeverForwardsCredentialBearingRequest() {
        let delegate = MusicServerRedirectDelegate()
        let source = URL(string: "https://music.example/rest/getAlbum.view?t=private")!
        let response = HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: source)
        for value in ["https://evil.example/path", "http://music.example/path", "https://music.example/path"] {
            var request = URLRequest(url: URL(string: value)!)
            request.setValue("music-token=private", forHTTPHeaderField: "Cookie")
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
                XCTAssertNil(redirected)
            }
        }
        task.cancel()
    }

    func testHTTPRedirectResponseIsAnErrorAndNeverLeaksCredentialsInError() async throws {
        MusicServerTestURLProtocol.handler = { _ in
            .init(status: 307, headers: ["Location": "https://evil.example/private-token"], data: Data())
        }
        let provider = try provider(.feiniu)
        do {
            _ = try await provider.listDirectory(path: "/")
            XCTFail("Redirects must fail")
        } catch MusicServerFailure.redirected { }
        catch { XCTFail("Unexpected error: \(error)") }
        await provider.disconnect()
    }

    func testDownloadRejectsErrorEnvelopeEvenIfNamedFLAC() async throws {
        let body = Data("{\"subsonic-response\":{\"status\":\"failed\"}}".utf8)
        MusicServerTestURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "getSong.view" {
                return try .subsonic(["song": ["id": "s", "path": "original.flac", "size": body.count]])
            }
            return .init(headers: ["Content-Type": "application/octet-stream"], data: body)
        }
        let provider = try provider(.subsonic)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("original.flac")
        do {
            try await provider.download(RemoteFile(id: "/subsonic/song/cw", name: "original.flac", isDirectory: false),
                                        to: destination) { _, _ in }
            XCTFail("Error envelopes must not become audio files")
        } catch MusicServerFailure.invalidAudio { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await provider.disconnect()
    }

    func testChangedFilenameStopsBeforeMediaDownload() async throws {
        MusicServerTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "getSong.view")
            return try .subsonic(["song": ["id": "s", "path": "renamed.flac"]])
        }
        let provider = try provider(.subsonic)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await provider.download(RemoteFile(id: "/subsonic/song/cw", name: "original.flac", isDirectory: false),
                                        to: directory.appendingPathComponent("original.flac")) { _, _ in }
            XCTFail("Changed source names must be refreshed")
        } catch MusicServerFailure.changedFile { }
        catch { XCTFail("Unexpected error: \(error)") }
        await provider.disconnect()
    }

    func testCancellationStopsCatalogRequest() async throws {
        let started = expectation(description: "Request started")
        MusicServerTestURLProtocol.handler = { _ in
            started.fulfill()
            return .init(data: Data(), stalls: true)
        }
        let provider = try provider(.subsonic)
        let task = Task { try await provider.listDirectory(path: "/") }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled browse must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
        await provider.disconnect()
    }

    func testMusicSourcesOverlapDownloadsAndCancelOneWithoutStoppingOthers() async throws {
        for kind in [ConnectionKind.subsonic, .navidrome, .feiniu] {
            let audio = Data("fLaC-concurrent-original".utf8)
            let streamsStarted = expectation(description: "Three \(kind) streams started")
            streamsStarted.expectedFulfillmentCount = 3
            let gate = MusicServerReplyGate()
            defer { gate.release() }
            MusicServerTestURLProtocol.handler = { request in
                let query = Self.query(request)
                let id = query["id"] ?? query["guid"] ?? ""
                switch request.url?.lastPathComponent {
                case "password-login": return try .feiniu(["userToken": "token"])
                case "metadata": return try .feiniu(["track": ["guid": id, "path": "\(id).flac", "size": audio.count]])
                case "getSong.view": return try .subsonic(["song": ["id": id, "path": "\(id).flac", "size": audio.count]])
                case "stream", "download.view":
                    streamsStarted.fulfill()
                    return .init(headers: ["Content-Type": "audio/flac"], data: audio, gate: gate)
                default: throw MusicServerTestError.unexpectedRequest
                }
            }
            let provider = try provider(kind)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let tasks = ["a", "b", "c"].map { id in
                Task {
                    try await provider.download(Self.track(id, kind: kind, size: audio.count),
                                                to: directory.appendingPathComponent("\(id).flac")) { _, _ in }
                }
            }
            await fulfillment(of: [streamsStarted], timeout: 3)
            tasks[0].cancel()
            do { try await tasks[0].value; XCTFail("The selected transfer must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
            gate.release()
            for task in tasks.dropFirst() { try await task.value }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.flac").path))
            for id in ["b", "c"] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(id).flac")), audio) }
            await provider.disconnect()
        }
    }

    func testFeiniuCoalescesConcurrentLoginAndCancelsOnlyTheSelectedWaiter() async throws {
        let audio = Data("fLaC-shared-login".utf8)
        let loginStarted = expectation(description: "Shared login started")
        let callersStarted = expectation(description: "All callers started")
        callersStarted.expectedFulfillmentCount = 3
        let cancelled = expectation(description: "Cancelled waiter returned before login")
        let gate = MusicServerReplyGate()
        defer { gate.release() }
        let log = MusicServerRequestLog()
        MusicServerTestURLProtocol.handler = { request in
            log.append(request)
            let id = Self.query(request)["guid"] ?? ""
            switch request.url?.lastPathComponent {
            case "password-login":
                loginStarted.fulfill()
                var reply = try MusicServerTestURLProtocol.Reply.feiniu(["userToken": "shared-token"])
                reply.gate = gate
                return reply
            case "metadata": return try .feiniu(["track": ["guid": id, "path": "\(id).flac", "size": audio.count]])
            case "stream": return .init(headers: ["Content-Type": "audio/flac"], data: audio)
            default: throw MusicServerTestError.unexpectedRequest
            }
        }
        let provider = try provider(.feiniu)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = ["a", "b", "c"].map { id in
            Task {
                callersStarted.fulfill()
                do {
                    try await provider.download(Self.track(id, kind: .feiniu, size: audio.count),
                                                to: directory.appendingPathComponent("\(id).flac")) { _, _ in }
                } catch {
                    if id == "a", error is CancellationError { cancelled.fulfill() }
                    throw error
                }
            }
        }
        await fulfillment(of: [callersStarted, loginStarted], timeout: 3)
        // Let the callers enter the actor while the actual HTTP reply stays gated.
        try await Task.sleep(nanoseconds: 30_000_000)
        tasks[0].cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 1)
        gate.release()
        _ = try? await tasks[0].value
        for task in tasks.dropFirst() { try await task.value }
        XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 1)
        await provider.disconnect()
    }

    func testFeiniuSharesRefreshAndReusesNewTokenForLateUnauthorizedResponse() async throws {
        let audio = Data("fLaC-refreshed-original".utf8)
        let rejected = expectation(description: "Three requests use old token")
        rejected.expectedFulfillmentCount = 3
        let refreshStarted = expectation(description: "One refresh started")
        let failures = MusicServerReplyGate(), lateFailure = MusicServerReplyGate(), refresh = MusicServerReplyGate()
        defer { failures.release(); lateFailure.release(); refresh.release() }
        let log = MusicServerRequestLog()
        MusicServerTestURLProtocol.handler = { request in
            log.append(request)
            let id = Self.query(request)["guid"] ?? ""
            switch request.url?.lastPathComponent {
            case "password-login":
                let isRefresh = log.requests.filter { $0.httpMethod == "POST" }.count > 1
                var reply = try MusicServerTestURLProtocol.Reply.feiniu(["userToken": isRefresh ? "new" : "old"])
                if isRefresh { refreshStarted.fulfill(); reply.gate = refresh }
                return reply
            case "metadata":
                if id != "warm", request.value(forHTTPHeaderField: "Cookie") == "music-token=old" {
                    rejected.fulfill()
                    return .init(status: 401, data: Data(), gate: id == "c" ? lateFailure : failures)
                }
                return try .feiniu(["track": ["guid": id, "path": "\(id).flac", "size": audio.count]])
            case "stream": return .init(headers: ["Content-Type": "audio/flac"], data: audio)
            default: throw MusicServerTestError.unexpectedRequest
            }
        }
        let provider = try provider(.feiniu)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await provider.download(Self.track("warm", kind: .feiniu, size: audio.count),
                                    to: directory.appendingPathComponent("warm.flac")) { _, _ in }
        let tasks = ["a", "b", "c"].map { id in
            Task {
                try await provider.download(Self.track(id, kind: .feiniu, size: audio.count),
                                            to: directory.appendingPathComponent("\(id).flac")) { _, _ in }
            }
        }
        await fulfillment(of: [rejected], timeout: 3)
        failures.release()
        await fulfillment(of: [refreshStarted], timeout: 3)
        refresh.release()
        for task in tasks.prefix(2) { try await task.value }
        lateFailure.release()
        try await tasks[2].value
        XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 2)
        for id in ["a", "b", "c"] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(id).flac")), audio) }
        await provider.disconnect()
    }

    func testFeiniuMediaAuthenticationRetriesAtMostOnce() async throws {
        for alwaysReject in [false, true] {
            let audio = Data("fLaC-media-retry".utf8)
            let log = MusicServerRequestLog()
            MusicServerTestURLProtocol.handler = { request in
                log.append(request)
                switch request.url?.lastPathComponent {
                case "password-login":
                    return try .feiniu(["userToken": "token-\(log.requests.filter { $0.httpMethod == "POST" }.count)"])
                case "metadata": return try .feiniu(["track": ["guid": "a", "path": "a.flac", "size": audio.count]])
                case "stream":
                    if alwaysReject || request.value(forHTTPHeaderField: "Cookie") == "music-token=token-1" {
                        return .init(status: 401, data: Data())
                    }
                    return .init(headers: ["Content-Type": "audio/flac"], data: audio)
                default: throw MusicServerTestError.unexpectedRequest
                }
            }
            let provider = try provider(.feiniu)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("a.flac")
            do {
                try await provider.download(Self.track("a", kind: .feiniu, size: audio.count), to: destination) { _, _ in }
                XCTAssertFalse(alwaysReject)
                XCTAssertEqual(try Data(contentsOf: destination), audio)
            } catch MusicServerFailure.authentication {
                XCTAssertTrue(alwaysReject)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
            XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 2)
            XCTAssertEqual(log.requests.filter { $0.url?.lastPathComponent == "stream" }.count, 2)
            await provider.disconnect()
        }
    }

    func testFeiniuCancellationAndDisconnectStopPendingSharedLogin() async throws {
        for disconnect in [false, true] {
            let started = expectation(description: "Pending login")
            let stopped = expectation(description: "Login HTTP request cancelled")
            MusicServerTestURLProtocol.handler = { _ in
                started.fulfill()
                return .init(data: Data(), stalls: true, onStop: { stopped.fulfill() })
            }
            let provider = try provider(.feiniu)
            let task = Task { try await provider.listDirectory(path: "/") }
            await fulfillment(of: [started], timeout: 3)
            if disconnect { await provider.disconnect() } else { task.cancel() }
            do { _ = try await task.value; XCTFail("Pending authentication must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
            await fulfillment(of: [stopped], timeout: 3)
            await provider.disconnect()
        }
    }

    private static func track(_ id: String, kind: ConnectionKind, size: Int) -> RemoteFile {
        let prefix = kind == .feiniu ? "/feiniu/song/" : "/subsonic/song/"
        let encoded = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return RemoteFile(id: prefix + encoded, name: "\(id).flac", isDirectory: false, size: Int64(size))
    }

    private func provider(_ kind: ConnectionKind, address: String = "https://music.example", allowsHTTP: Bool = false) throws -> MusicServerFileProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicServerTestURLProtocol.self]
        let connection = RemoteConnection(kind: kind, name: "Test", address: address, username: "listener",
                                          allowsInsecureConnection: allowsHTTP)
        return try MusicServerFileProvider(connection: connection, password: "test-password", configuration: config)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MusicServerConnectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? MusicServerTestError.unexpectedRequest }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}

private enum MusicServerTestError: Error { case unexpectedRequest }

private final class MusicServerRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class MusicServerReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var pending: [() -> Void] = []

    func enqueue(_ deliver: @escaping () -> Void) {
        lock.lock()
        if opened { lock.unlock(); deliver() }
        else { pending.append(deliver); lock.unlock() }
    }

    func release() {
        lock.lock()
        opened = true
        let deliveries = pending
        pending = []
        lock.unlock()
        deliveries.forEach { $0() }
    }
}

private final class MusicServerTestURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var data: Data
        var stalls = false
        var gate: MusicServerReplyGate?
        var onStop: (() -> Void)?

        static func subsonic(_ values: [String: Any]) throws -> Reply {
            var envelope = values
            envelope["status"] = "ok"
            return .init(data: try JSONSerialization.data(withJSONObject: ["subsonic-response": envelope]))
        }

        static func feiniu(_ data: [String: Any]) throws -> Reply {
            .init(data: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]))
        }
    }

    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> Reply)?
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    private var onStop: (() -> Void)?
    static var handler: ((URLRequest) throws -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw MusicServerTestError.unexpectedRequest }
            let reply = try handler(request)
            deliveryLock.lock()
            let alreadyStopped = stopped
            onStop = alreadyStopped ? nil : reply.onStop
            deliveryLock.unlock()
            if alreadyStopped { reply.onStop?(); return }
            if reply.stalls { return }
            if let gate = reply.gate { gate.enqueue { [weak self] in self?.deliver(reply) } }
            else { deliver(reply) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func deliver(_ reply: Reply) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.lock()
        stopped = true
        let callback = onStop
        onStop = nil
        deliveryLock.unlock()
        callback?()
    }
}
