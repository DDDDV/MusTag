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

struct AudioArtwork: Codable, Equatable, Sendable {
    var data: Data
    var mimeType: String
}

struct AudioSnapshot: Sendable {
    var tags: AudioTags
    var duration: Double
    var artwork: AudioArtwork? = nil
}

struct ShazamAttribution: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var appleMusicURL: URL?
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
    var originalArtwork: AudioArtwork? = nil
    var draftArtwork: AudioArtwork? = nil
    // Missing on pre-artwork library entries; populated on their first refresh.
    var artworkVersion: Int? = 1
    // Missing on older entries and empty for individually imported files.
    var importFolderIDs: Set<String>? = nil
    var originalShazamAttribution: ShazamAttribution? = nil
    var draftShazamAttribution: ShazamAttribution? = nil
    var fileName: String { url.lastPathComponent }
    var hasArtworkChanges: Bool { originalArtwork != draftArtwork }
    var hasChanges: Bool { original != draft || hasArtworkChanges }
}

struct AudioFolder: Identifiable, Codable, Hashable, Sendable {
    var url: URL
    var id: String { url.standardizedFileURL.absoluteString }
    var name: String { url.lastPathComponent }
}

struct AudioLibrary: Codable, Sendable {
    var documents: [AudioDocument]
    var folders: [AudioFolder]
}

enum RecognitionProvider: String, CaseIterable, Identifiable, Sendable {
    case shazamKit
    case acoustID

    var id: String { rawValue }
    var title: String { self == .shazamKit ? "ShazamKit" : "AcoustID" }
}

enum MetadataSource: Sendable {
    case musicBrainz, acoustID, shazamKit
}

struct MetadataCandidate: Identifiable, Sendable {
    var id: String
    // MusicBrainz identifiers only. Shazam identifiers must never enter MB/CAA URLs.
    var recordingID: String?
    var releaseID: String?
    var tags: AudioTags
    var duration: Double?
    var score: Double?
    var detail: String
    var hasIncompleteReleaseInfo = false
    var source: MetadataSource = .musicBrainz
    var artworkURL: URL? = nil
    var appleMusicURL: URL? = nil
    var isrc: String? = nil
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
    var originalShazamAttribution: ShazamAttribution? = nil
}

struct ImportResult: Sendable {
    var documents: [AudioDocument]
    var failures: [String]
    var folders: [AudioFolder] = []
}

protocol AudioMetadataCodec: Sendable {
    func read(from url: URL) throws -> AudioSnapshot
    func write(_ tags: AudioTags, to url: URL) throws
    func writeArtwork(_ artwork: AudioArtwork, to url: URL) throws
}

extension AudioMetadataCodec {
    func writeArtwork(_ artwork: AudioArtwork, to url: URL) throws {
        throw MusTagError.message(L10n.text("This format cannot save cover art.", "此格式无法保存封面。"))
    }
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
