import Foundation

struct NativeMetadataCodec: AudioMetadataCodec {
    func read(from url: URL) throws -> AudioSnapshot {
        let raw = try MTTagBridge.read(url: url)
        let tags = raw["tags"] as? [String: String] ?? [:]
        return AudioSnapshot(tags: AudioTags(
            title: tags["title"] ?? "", artist: tags["artist"] ?? "",
            album: tags["album"] ?? "", albumArtist: tags["albumArtist"] ?? "",
            year: tags["year"] ?? "", trackNumber: tags["trackNumber"] ?? "",
            discNumber: tags["discNumber"] ?? "", genre: tags["genre"] ?? ""
        ), duration: (raw["duration"] as? NSNumber)?.doubleValue ?? 0)
    }

    func write(_ tags: AudioTags, to url: URL) throws {
        try MTTagBridge.write(tags: [
            "title": tags.title, "artist": tags.artist, "album": tags.album,
            "albumArtist": tags.albumArtist, "year": tags.year,
            "trackNumber": tags.trackNumber, "discNumber": tags.discNumber, "genre": tags.genre
        ], to: url)
    }
}
