import Foundation
import Security

enum ConnectionProviderFactory {
    static func make(_ connection: RemoteConnection, password: String) throws -> any RemoteFileProvider {
        switch connection.kind {
        case .webDAV: return try WebDAVFileProvider(connection: connection, password: password)
        case .ftp: return try FTPFileProvider(connection: connection, password: password)
        case .smb: return try SMBFileProvider(connection: connection, password: password)
        case .subsonic, .navidrome, .feiniu:
            return try MusicServerFileProvider(connection: connection, password: password)
        }
    }
}

enum ConnectionPasswordStore {
    static func password(for id: UUID) throws -> String {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw MusTagError.message(L10n.text("Open connection settings and enter the password again.", "请打开连接设置，重新输入密码。"))
        }
        return value
    }

    static func set(_ password: String, for id: UUID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let base = query(id)
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MusTagError.message(L10n.text("Could not save connection credentials (\(status)).", "无法保存连接凭据（\(status)）。"))
        }
    }

    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MusTagError.message(L10n.text("Could not remove connection credentials.", "无法删除连接凭据。"))
        }
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MusTag.Connections",
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [RemoteConnection] = []
    @Published var error: String?
    private let fileURL: URL
    private var canWrite = false

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusTag", isDirectory: true)
        fileURL = root.appendingPathComponent("connections.json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                connections = try JSONDecoder().decode([RemoteConnection].self, from: Data(contentsOf: fileURL))
            }
            canWrite = true
        } catch { self.error = L10n.text("Could not read saved connections. Existing settings were kept.", "无法读取已保存的连接，现有设置已保留。") }
    }

    func save(_ connection: RemoteConnection, password: String) throws {
        guard canWrite else { throw MusTagError.message(error ?? "Connection settings unavailable") }
        // Never persist passwords supplied in an address or token-bearing URLs.
        let candidate = connection.address.contains("://") ? connection.address : "scheme://" + connection.address
        guard let url = URLComponents(string: candidate), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw MusTagError.message(L10n.text("Use a server address without credentials or query parameters. Enter the account below.", "服务器地址不能包含账号、密码或查询参数，请在下方填写账号。"))
        }
        let previousPassword = try? ConnectionPasswordStore.password(for: connection.id)
        try ConnectionPasswordStore.set(password, for: connection.id)
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        do { try persist(updated) }
        catch {
            if let previousPassword { try? ConnectionPasswordStore.set(previousPassword, for: connection.id) }
            else { try? ConnectionPasswordStore.remove(connection.id) }
            throw error
        }
        connections = updated
    }

    func remove(_ connection: RemoteConnection) throws {
        guard canWrite else { throw MusTagError.message(error ?? "Connection settings unavailable") }
        let updated = connections.filter { $0.id != connection.id }
        try persist(updated)
        connections = updated
        try ConnectionPasswordStore.remove(connection.id)
    }

    private func persist(_ connections: [RemoteConnection]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(connections).write(to: fileURL, options: .atomic)
    }
}

extension Notification.Name {
    static let musTagLocalFilesAdded = Notification.Name("MusTag.localFilesAdded")
}
