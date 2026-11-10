import Foundation

enum RemoteTransportError: LocalizedError, Equatable {
    case invalidAddress, invalidPath, insecureConnection, invalidResponse, authentication, notFound
    case server(Int)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: L10n.text("Enter a valid server address without embedded credentials.", "请输入有效的服务器地址，账号密码请单独填写。")
        case .invalidPath: L10n.text("The server returned an invalid file path.", "服务器文件路径无效。")
        case .insecureConnection: L10n.text("Confirm the unencrypted connection before continuing.", "请先确认允许未加密连接。")
        case .invalidResponse: L10n.text("The server returned an invalid or incomplete response.", "服务器响应无效或不完整。")
        case .authentication: L10n.text("Authentication failed. Check the username and password.", "认证失败，请检查账号和密码。")
        case .notFound: L10n.text("The remote file or folder was not found.", "未找到远程文件或文件夹。")
        case .server(let code): L10n.text("Server error (\(code)).", "服务器错误（\(code)）。")
        }
    }
}

enum RemoteFilePaths {
    static func components(_ path: String) throws -> [String] {
        guard !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteTransportError.invalidPath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw RemoteTransportError.invalidPath }
        return parts
    }
    static func logical(_ path: String) throws -> String { "/" + (try components(path)).joined(separator: "/") }
    static func child(_ name: String, of parent: String) throws -> String {
        guard !name.isEmpty, try components(name) == [name] else { throw RemoteTransportError.invalidPath }
        return "/" + ((try components(parent)) + [name]).joined(separator: "/")
    }
    static func endpoint(_ address: String, defaultScheme: String, schemes: Set<String>) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw RemoteTransportError.invalidAddress }
        _ = try components(url.path)
        return url
    }
    static func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// A failed transfer only removes its own staging file, never a pre-existing destination.
final class RemoteDownloadStage {
    let url: URL
    let handle: FileHandle
    private let destination: URL
    init(destination: URL) throws {
        guard destination.isFileURL else { throw RemoteTransportError.invalidPath }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        self.destination = destination
        url = destination.deletingLastPathComponent().appendingPathComponent(".mustag-download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }
    func finish() throws {
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        // moveItem refuses to overwrite a destination that appeared during the transfer.
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

final class RemoteCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [UUID: @Sendable () -> Void] = [:]
    private var cancelled = false
    func add(_ action: @escaping @Sendable () -> Void) -> UUID {
        lock.lock()
        let id = UUID(); let shouldCancel = cancelled
        if !shouldCancel { actions[id] = action }
        lock.unlock()
        if shouldCancel { action() }
        return id
    }
    func remove(_ id: UUID) { lock.lock(); actions[id] = nil; lock.unlock() }
    func cancelAll() {
        lock.lock(); cancelled = true; let pending = Array(actions.values); actions.removeAll(); lock.unlock()
        pending.forEach { $0() }
    }
}
