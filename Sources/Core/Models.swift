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
    var metadata: ShazamRecognitionResult? = nil
    var appleMusicMetadata: AppleMusicSongMetadata? = nil
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
    /// Import provenance only. Saving always targets the owned local copy in `url`.
    var sourceURL: URL? = nil
    /// Relative to Documents/Music, so an app container relocation keeps files usable.
    var libraryRelativePath: String? = nil
    var fileName: String { url.lastPathComponent }
    var hasArtworkChanges: Bool { originalArtwork != draftArtwork }
    var hasChanges: Bool { original != draft || hasArtworkChanges }
    var missingTagFields: [TagField] {
        TagField.allCases.filter {
            $0.value(in: draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var isMissingArtwork: Bool {
        // A legacy entry's cover is unknown until its first successful refresh.
        artworkVersion != nil && (draftArtwork?.data.isEmpty ?? true)
    }
}

struct AudioFolder: Identifiable, Codable, Hashable, Sendable {
    var url: URL
    var sourceURL: URL? = nil
    var libraryRelativePath: String? = nil
    var persistentID: String? = nil
    var id: String { persistentID ?? (sourceURL ?? url).standardizedFileURL.absoluteString }
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
    case acoustID, shazamKit
}

enum CandidateReleaseChoice: Sendable {
    case keepOriginal, appleMusic
}

struct MetadataCandidate: Identifiable, Sendable {
    var id: String
    var tags: AudioTags
    var duration: Double?
    var score: Double?
    var detail: String
    var hasIncompleteReleaseInfo = false
    var source: MetadataSource = .acoustID
    var artworkURL: URL? = nil
    var appleMusicURL: URL? = nil
    var isrc: String? = nil
    var shazamMetadata: ShazamRecognitionResult? = nil
    var appleMusicMetadata: AppleMusicSongMetadata? = nil
    var supplementationNotice: String? = nil

    func hasAlbumConflict(with originalAlbum: String) -> Bool {
        guard source == .shazamKit, appleMusicMetadata != nil else { return false }
        func normalized(_ album: String) -> String {
            album.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").lowercased()
        }
        let original = normalized(originalAlbum)
        let proposed = normalized(tags.album)
        return !original.isEmpty && !proposed.isEmpty && original != proposed
    }
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
    // Absent in legacy journals, whose backup is a complete audio file.
    // New archives contain only metadata and have their own integrity hash.
    var backupHash: String? = nil
    var libraryRelativePath: String? = nil
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
