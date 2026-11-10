import Foundation
@preconcurrency import SMBClient

struct SMBFileProvider: RemoteFileProvider {
    private let endpoint: URL
    private let base: [String]
    private let username: String
    private let password: String
    private let domain: String
    private let active = RemoteCancellationRegistry()

    init(connection: RemoteConnection, password: String) throws {
        endpoint = try RemoteFilePaths.endpoint(connection.address, defaultScheme: "smb", schemes: ["smb"])
        base = try RemoteFilePaths.components(endpoint.path) + RemoteFilePaths.components(connection.rootPath)
        username = connection.username; self.password = password; domain = connection.domain
    }
    func disconnect() async { active.cancelAll() }

    /// Without a configured share, logical root lists shares; otherwise it is relative to that share/root.
    func location(for path: String) throws -> (share: String?, path: String) {
        let parts = base + (try RemoteFilePaths.components(path))
        return (parts.first, parts.dropFirst().joined(separator: "\\"))
    }

    private func perform<T: Sendable>(_ body: (SMBReadSession) async throws -> T) async throws -> T {
        let box = try SMBReadSession(host: endpoint.host!, port: endpoint.port ?? 445)
        let token = active.add { box.cancel() }
        defer { active.remove(token); box.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            box.touch()
            try await box.session.negotiate()
            box.touch()
            try await box.session.sessionSetup(username: username.isEmpty ? nil : username,
                                               password: password.isEmpty ? nil : password,
                                               domain: domain.isEmpty ? nil : domain)
            return try await body(box)
        } onCancel: { box.cancel() }
    }

    func listDirectory(path: String) async throws -> [RemoteFile] {
        let target = try location(for: path)
        return try await perform { box in
            guard let share = target.share else {
                box.touch()
                let shares = try await box.session.enumShareAll()
                try Task.checkCancellation()
                return RemoteFilePaths.sorted(shares.compactMap { share in
                    guard share.type.rawValue & 0x000000FF == 0, !share.name.hasSuffix("$"),
                          let id = try? RemoteFilePaths.child(share.name, of: "/") else { return nil }
                    return RemoteFile(id: id, name: share.name, isDirectory: true)
                })
            }
            box.touch()
            try await box.session.treeConnect(path: share)
            box.touch()
            let files = try await box.session.queryDirectory(path: target.path, pattern: "*")
            try Task.checkCancellation()
            return RemoteFilePaths.sorted(files.compactMap { item in
                guard let id = try? RemoteFilePaths.child(item.fileName, of: path) else { return nil }
                return RemoteFile(id: id, name: item.fileName, isDirectory: item.fileAttributes.contains(.directory),
                                  size: Int64(exactly: item.endOfFile),
                                  modifiedAt: Date(timeIntervalSince1970: Double(item.lastWriteTime) / 10_000_000 - 11_644_473_600))
            })
        }
    }

    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let target = try location(for: file.id)
        guard !file.isDirectory, let share = target.share, !target.path.isEmpty else { throw RemoteTransportError.invalidPath }
        let stage = try RemoteDownloadStage(destination: destination)
        try await perform { box in
            box.touch()
            try await box.session.treeConnect(path: share)
            box.touch()
            let opened = try await box.session.create(desiredAccess: [.genericRead], fileAttributes: [],
                                                      shareAccess: [.read], createDisposition: .open,
                                                      createOptions: [.nonDirectoryFile], name: target.path)
            guard let size = Int64(exactly: opened.endOfFile), box.session.maxReadSize > 0 else {
                throw RemoteTransportError.invalidResponse
            }
            var offset: UInt64 = 0
            progress(0, size)
            do {
                while offset < opened.endOfFile {
                    try Task.checkCancellation()
                    box.touch()
                    let length = UInt32(min(UInt64(min(box.session.maxReadSize, 256 * 1024)), opened.endOfFile - offset))
                    let response = try await box.session.read(fileId: opened.fileId, offset: offset, length: length)
                    let bytes = response.buffer
                    guard !bytes.isEmpty, bytes.count <= Int(length) else { throw RemoteTransportError.invalidResponse }
                    try stage.handle.write(contentsOf: bytes)
                    offset += UInt64(bytes.count)
                    progress(Int64(offset), size)
                }
                try Task.checkCancellation()
                box.touch()
                try await box.session.close(fileId: opened.fileId)
            } catch {
                // Disconnect closes the read handle as well, including when the server stops responding.
                box.cancel()
                throw error
            }
        }
        try stage.finish()
    }
}

/// Each operation has its own SMB session; cancel and timeout close its Network connection.
private final class SMBReadSession: @unchecked Sendable {
    let session: Session
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var cancelled = false
    init(host: String, port: Int) throws {
        session = try Session(host: host, port: port)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MusTag.SMB.timeout"))
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [session] in session.disconnect() }
        timer.resume()
    }
    func touch() {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { timer.schedule(deadline: .now() + 30) }
    }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true; timer.cancel(); lock.unlock()
        session.disconnect()
    }
}
