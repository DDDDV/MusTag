import Foundation
import Network

struct FTPFileProvider: RemoteFileProvider {
    private let endpoint: URL
    private let root: [String]
    private let username: String
    private let password: String
    private let active = RemoteCancellationRegistry()

    init(connection: RemoteConnection, password: String) throws {
        endpoint = try RemoteFilePaths.endpoint(connection.address, defaultScheme: "ftp", schemes: ["ftp"])
        guard connection.allowsInsecureConnection else { throw RemoteTransportError.insecureConnection }
        root = try RemoteFilePaths.components(endpoint.path) + RemoteFilePaths.components(connection.rootPath)
        username = connection.username.isEmpty ? "anonymous" : connection.username
        self.password = connection.username.isEmpty && password.isEmpty ? "anonymous@" : password
        try FTPControlSession.validateArgument(username)
        try FTPControlSession.validateArgument(self.password)
    }
    func disconnect() async { active.cancelAll() }
    private func remotePath(_ path: String) throws -> String {
        "/" + (root + (try RemoteFilePaths.components(path))).joined(separator: "/")
    }
    private func perform<T: Sendable>(_ body: (FTPControlSession) async throws -> T) async throws -> T {
        let registry = RemoteCancellationRegistry()
        let token = active.add { registry.cancelAll() }
        defer { active.remove(token); registry.cancelAll() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let control = FTPControlSession(host: endpoint.host!, port: endpoint.port ?? 21, registry: registry)
            try await control.login(username: username, password: password)
            return try await body(control)
        } onCancel: { registry.cancelAll() }
    }
    func listDirectory(path: String) async throws -> [RemoteFile] {
        let remote = try remotePath(path)
        return try await perform { control in
            let entries: [RemoteFile]
            do {
                let data = try await control.list(command: "MLSD \(remote)")
                entries = FTPListingParser.parseMLSD(data)
            } catch let error as FTPReply where [500, 501, 502, 504].contains(error.code) {
                entries = FTPListingParser.parseLIST(try await control.list(command: "LIST \(remote)"))
            }
            return RemoteFilePaths.sorted(entries.compactMap { entry in
                guard let id = try? RemoteFilePaths.child(entry.name, of: path) else { return nil }
                var file = entry; file.id = id; return file
            })
        }
    }
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard !file.isDirectory else { throw RemoteTransportError.invalidPath }
        let remote = try remotePath(file.id)
        let stage = try RemoteDownloadStage(destination: destination)
        try await perform { control in
            var received: Int64 = 0
            progress(0, file.size)
            try await control.transfer(command: "RETR \(remote)") { data in
                try Task.checkCancellation()
                try stage.handle.write(contentsOf: data)
                received += Int64(data.count)
                progress(received, file.size)
            }
            if let size = file.size, size != received { throw RemoteTransportError.invalidResponse }
        }
        try stage.finish()
    }
}

private struct FTPReply: Error, LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? {
        switch code {
        case 530: RemoteTransportError.authentication.errorDescription
        case 550: RemoteTransportError.notFound.errorDescription
        default: RemoteTransportError.server(code).errorDescription
        }
    }
    func require(_ codes: Set<Int>) throws { guard codes.contains(code) else { throw self } }
}

private final class FTPControlSession {
    let host: String
    let port: Int
    let registry: RemoteCancellationRegistry
    private let control: FTPStream
    private var buffer = Data()
    init(host: String, port: Int, registry: RemoteCancellationRegistry) {
        self.host = host; self.port = port; self.registry = registry
        control = FTPStream(host: host, port: port)
        _ = registry.add { [control] in control.cancel() }
    }
    static func validateArgument(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteTransportError.invalidPath
        }
    }
    func login(username: String, password: String) async throws {
        try await control.connect()
        var greeting = try await reply()
        if greeting.code == 120 { greeting = try await reply() }
        try greeting.require([220])
        let user = try await command("USER \(username)")
        if user.code != 230 {
            try user.require([331])
            try await command("PASS \(password)").require([230])
        }
        _ = try await command("OPTS UTF8 ON")
        try await command("TYPE I").require([200])
    }
    func list(command: String) async throws -> Data {
        var bytes = Data()
        try await transfer(command: command) { chunk in
            guard bytes.count + chunk.count <= 8 * 1024 * 1024 else { throw RemoteTransportError.invalidResponse }
            bytes.append(chunk)
        }
        return bytes
    }
    func transfer(command request: String, consume: (Data) throws -> Void) async throws {
        let passive = try await command("EPSV")
        let dataPort: Int
        if passive.code == 229, let port = FTPPassiveReply.epsvPort(passive.message) {
            dataPort = port
        } else {
            let reply = try await command("PASV")
            try reply.require([227])
            guard let port = FTPPassiveReply.pasvPort(reply.message) else { throw RemoteTransportError.invalidResponse }
            dataPort = port
        }
        // Always use the control server's host; never connect to an arbitrary PASV-supplied host.
        let data = FTPStream(host: host, port: dataPort)
        let token = registry.add { data.cancel() }
        defer { registry.remove(token); data.cancel() }
        try await data.connect()
        try await command(request).require([125, 150])
        while true {
            let chunk = try await data.receive()
            if !chunk.data.isEmpty { try consume(chunk.data) }
            if chunk.finished { break }
        }
        try await reply().require([226, 250])
        try Task.checkCancellation()
    }
    private func command(_ command: String) async throws -> FTPReply {
        try Self.validateArgument(command)
        try await control.send(Data((command + "\r\n").utf8))
        return try await reply()
    }
    private func line() async throws -> String {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let data = buffer[..<end]
                buffer.removeSubrange(...end)
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            guard buffer.count < 8192 else { throw RemoteTransportError.invalidResponse }
            let chunk = try await control.receive()
            buffer.append(chunk.data)
            if chunk.finished, !buffer.contains(10) { throw RemoteTransportError.invalidResponse }
        }
    }
    private func reply() async throws -> FTPReply {
        let first = try await line()
        guard first.count >= 3, let code = Int(first.prefix(3)), (100...599).contains(code) else {
            throw RemoteTransportError.invalidResponse
        }
        var lines = [first]
        if first.dropFirst(3).first == "-" {
            while lines.count < 100 {
                let next = try await line(); lines.append(next)
                if next.hasPrefix("\(code) ") { return FTPReply(code: code, message: lines.joined(separator: "\n")) }
            }
            throw RemoteTransportError.invalidResponse
        }
        return FTPReply(code: code, message: first)
    }
}

enum FTPPassiveReply {
    private static func payload(_ message: String) -> String? {
        guard let first = message.firstIndex(of: "("), let last = message[first...].firstIndex(of: ")") else { return nil }
        return String(message[message.index(after: first)..<last])
    }
    static func epsvPort(_ message: String) -> Int? {
        guard let value = payload(message), let separator = value.first else { return nil }
        let parts = value.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1].isEmpty, parts[2].isEmpty, parts[4].isEmpty,
              let port = Int(parts[3]), (1...65535).contains(port) else { return nil }
        return port
    }
    static func pasvPort(_ message: String) -> Int? {
        guard let value = payload(message) else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6, numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let port = numbers[4] * 256 + numbers[5]
        return port > 0 ? port : nil
    }
}

private struct FTPChunk: Sendable { let data: Data; let finished: Bool }

private final class FTPCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

private final class FTPStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MusTag.FTP")
    init(host: String, port: Int) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }
    func cancel() { connection.cancel() }
    private func wait<Value: Sendable>(_ start: @escaping (FTPCompletion<Value>) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                let result = FTPCompletion(continuation)
                queue.asyncAfter(deadline: .now() + 30) { [connection] in
                    if result.resolve(.failure(URLError(.timedOut))) { connection.cancel() }
                }
                start(result)
            }
            try Task.checkCancellation()
            return value
        } onCancel: { [connection] in connection.cancel() }
    }
    func connect() async throws {
        let _: Bool = try await wait { [connection, queue] result in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.resolve(.success(true))
                case .failed(let error): result.resolve(.failure(error))
                case .cancelled: result.resolve(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    func send(_ bytes: Data) async throws {
        let _: Bool = try await wait { [connection] result in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { result.resolve(.failure(error)) } else { result.resolve(.success(true)) }
            })
        }
    }
    func receive() async throws -> FTPChunk {
        try await wait { [connection] result in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { result.resolve(.failure(error)) }
                else { result.resolve(.success(FTPChunk(data: data ?? Data(), finished: complete))) }
            }
        }
    }
}

enum FTPListingParser {
    static func parseMLSD(_ data: Data) -> [RemoteFile] {
        String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            guard (try? RemoteFilePaths.components(name)) == [name] else { return nil }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let values = fact.split(separator: "=", maxSplits: 1)
                if values.count == 2 { facts[String(values[0]).lowercased()] = String(values[1]) }
            }
            let type = facts["type"]?.lowercased()
            guard type == "dir" || type == "file" else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
            let modified = facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) }
            return RemoteFile(id: name, name: name, isDirectory: type == "dir", size: facts["size"].flatMap(Int64.init), modifiedAt: modified)
        }
    }
    static func parseLIST(_ data: Data) -> [RemoteFile] {
        let unix = try! NSRegularExpression(pattern: #"^([d-])[rwxstST-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{4}|\d{1,2}:\d{2})\s(.+)$"#)
        let dos = try! NSRegularExpression(pattern: #"^\d{2}-\d{2}-\d{2,4}\s+\d{1,2}:\d{2}(?:AM|PM)\s+(<DIR>|\d+)\s+(.+)$"#, options: .caseInsensitive)
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            let name: String; let directory: Bool; let size: Int64?
            if let match = unix.firstMatch(in: line, range: range) {
                directory = group(match, 1) == "d"; size = Int64(group(match, 2)); name = group(match, 6)
            } else if let match = dos.firstMatch(in: line, range: range) {
                directory = group(match, 1).uppercased() == "<DIR>"; size = Int64(group(match, 1)); name = group(match, 2)
            } else { return nil }
            guard (try? RemoteFilePaths.components(name)) == [name] else { return nil }
            return RemoteFile(id: name, name: name, isDirectory: directory, size: size)
        }
    }
}
