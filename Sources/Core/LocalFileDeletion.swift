import Foundation

struct LocalFileEntry: Identifiable, Sendable {
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let fileSize: Int64
    var id: String { relativePath }
    var name: String { url.lastPathComponent }
}

/// A confirmation describes a fixed snapshot, never permission to recursively
/// delete whatever happens to occupy a folder when the user confirms later.
struct LocalDeletionPlan: Identifiable, Codable, Sendable {
    var id = UUID()
    let roots: [URL]
    let rootIdentity: LocalFileIdentity
    let entries: [LocalDeletionEntry]
    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var folderCount: Int { entries.filter(\.isDirectory).count }
    var totalBytes: Int64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + ($1.identity?.size ?? 0) } }
}

struct LocalDeletionEntry: Codable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let identity: LocalFileIdentity?
}

struct LocalFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    func matches(_ other: LocalFileIdentity, isDirectory: Bool) -> Bool {
        device == other.device && inode == other.inode
            && (isDirectory || (size == other.size && modifiedSeconds == other.modifiedSeconds
                               && modifiedNanoseconds == other.modifiedNanoseconds))
    }
}

struct LocalDeletionResult: Sendable {
    let library: AudioLibrary
    let deletedPaths: Set<String>
    let deletedFileCount: Int
    let deletedFolderCount: Int
    let failures: [String]
}
