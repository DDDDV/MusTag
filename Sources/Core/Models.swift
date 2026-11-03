import Foundation

struct AudioTags: Codable, Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var year = ""
    var trackNumber = ""
    var discNumber = ""
    var genre = ""

    static let empty = AudioTags()
    var hasAnyValue: Bool {
        [title, artist, album, albumArtist, year, trackNumber, discNumber, genre]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct AudioSnapshot: Sendable {
    var tags: AudioTags
    var duration: Double
}

struct AudioDocument: Identifiable, Codable, Sendable {
    var id = UUID()
    var url: URL
    var bookmark: Data?
    var original: AudioTags
    var draft: AudioTags
    var duration: Double
    var error: String?
    var sourceHash: String = ""
    var fileName: String { url.lastPathComponent }
    var hasChanges: Bool { original != draft }
}

struct MetadataCandidate: Identifiable, Sendable {
    var id: String
    var recordingID: String
    var releaseID: String?
    var tags: AudioTags
    var duration: Double?
    var score: Double?
    var detail: String
}

struct BackupRecord: Identifiable, Codable, Sendable {
    var id = UUID()
    var documentID: UUID
    var originalURL: URL
    var bookmark: Data?
    var backupURL: URL
    var createdAt = Date()
    var originalHash: String
    var writtenHash: String
    var restored = false
}

struct ImportResult: Sendable {
    var documents: [AudioDocument]
    var failures: [String]
}

protocol AudioMetadataCodec: Sendable {
    func read(from url: URL) throws -> AudioSnapshot
    func write(_ tags: AudioTags, to url: URL) throws
}

enum MusTagError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum L10n {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }
    static func text(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}
