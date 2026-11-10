import Foundation

enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case webDAV, smb, ftp, subsonic, navidrome, feiniu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .webDAV: "WebDAV"
        case .smb: "SMB"
        case .ftp: "FTP"
        case .subsonic: "Subsonic"
        case .navidrome: "Navidrome"
        case .feiniu: L10n.text("FeiNiu Music", "飞牛音乐")
        }
    }
    var isMusicServer: Bool { [.subsonic, .navidrome, .feiniu].contains(self) }
}

/// Contains connection settings only. Passwords are held separately in Keychain.
struct RemoteConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: ConnectionKind
    var name: String
    var address: String
    var username: String
    var rootPath: String = "/"
    var domain: String = ""
    var allowsInsecureConnection = false
}

struct RemoteFile: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var isDirectory: Bool
    var size: Int64? = nil
    var modifiedAt: Date? = nil
    var unavailableReason: String? = nil
    var isSupportedAudio: Bool {
        unavailableReason == nil && !isDirectory && ["mp3", "flac", "m4a"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// Deliberately read-only: there is no remote upload, rename, delete, or metadata API.
protocol RemoteFileProvider: Sendable {
    func listDirectory(path: String) async throws -> [RemoteFile]
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
    func disconnect() async
}

extension RemoteFileProvider {
    func disconnect() async { }
}

enum ConnectionPaths {
    static func component(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    static func validateRelativePath(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw MusTagError.message(L10n.text("Invalid file path.", "文件路径无效。"))
        }
        return parts
    }
}
