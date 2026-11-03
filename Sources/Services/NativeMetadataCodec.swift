import Foundation

struct NativeMetadataCodec: AudioMetadataCodec {
    func read(from url: URL) throws -> AudioSnapshot {
        let raw = try MTTagBridge.read(url: url)
        let tags = raw["tags"] as? [String: String] ?? [:]
        let image = raw["artwork"] as? [String: Any]
        let artwork: AudioArtwork?
        if let data = image?["data"] as? Data, let mimeType = image?["mimeType"] as? String {
            artwork = AudioArtwork(data: data, mimeType: mimeType)
        } else { artwork = nil }
        return AudioSnapshot(tags: AudioTags(
            title: tags["title"] ?? "", artist: tags["artist"] ?? "",
            album: tags["album"] ?? "", albumArtist: tags["albumArtist"] ?? "",
            year: tags["year"] ?? "", trackNumber: tags["trackNumber"] ?? "",
            discNumber: tags["discNumber"] ?? "", genre: tags["genre"] ?? ""
        ), duration: (raw["duration"] as? NSNumber)?.doubleValue ?? 0, artwork: artwork)
    }

    func write(_ tags: AudioTags, to url: URL) throws {
        try MTTagBridge.write(tags: [
            "title": tags.title, "artist": tags.artist, "album": tags.album,
            "albumArtist": tags.albumArtist, "year": tags.year,
            "trackNumber": tags.trackNumber, "discNumber": tags.discNumber, "genre": tags.genre
        ], to: url)
    }

    func writeArtwork(_ artwork: AudioArtwork, to url: URL) throws {
        try MTTagBridge.writeArtwork(artwork.data, mimeType: artwork.mimeType, to: url)
    }
}
