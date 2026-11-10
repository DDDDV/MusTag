import Foundation

typealias AudioPayloadRange = (offset: UInt64, length: UInt64)

/// A lossless metadata snapshot. Encoded audio is represented only by byte counts;
/// restoring borrows those bytes from the unchanged audio in the current file.
/// Keeping original container bytes also preserves unknown tags, multiple covers,
/// absent tags, padding, and M4A offsets without normalizing them through a writer.
struct AudioMetadataBackup: Codable, Sendable {
    private struct Segment: Codable, Sendable {
        var metadata: Data?
        var audioLength: UInt64?
    }

    private var version: Int
    private var segments: [Segment]
    let originalFileSize: UInt64
    let audioByteCount: UInt64

    static func capture(from source: URL, audioRanges: [AudioPayloadRange]) throws -> AudioMetadataBackup {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        let audioSize = try validateRanges(audioRanges, fileSize: size)
        var segments: [Segment] = []
        var offset: UInt64 = 0
        for range in audioRanges {
            try Task.checkCancellation()
            if range.offset > offset {
                segments.append(Segment(metadata: try readMetadata(input, offset: offset,
                                                                   length: range.offset - offset)))
            }
            segments.append(Segment(audioLength: range.length))
            offset = range.offset + range.length
        }
        if offset < size {
            segments.append(Segment(metadata: try readMetadata(input, offset: offset, length: size - offset)))
        }
        return AudioMetadataBackup(version: 1, segments: segments, originalFileSize: size,
                                   audioByteCount: audioSize)
    }

    init(data: Data) throws {
        self = try PropertyListDecoder().decode(Self.self, from: data)
        try validate()
    }

    func encodedData() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Audio ranges may move or be split differently after a tag edit. Their
    /// concatenated bytes are streamed back into the original segment layout.
    /// Callers must verify the source and reconstructed file hashes before replacing.
    func restore(from source: URL, audioRanges: [AudioPayloadRange], to destination: URL) throws {
        try validate()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard try Self.validateRanges(audioRanges, fileSize: size) == audioByteCount else {
            throw Self.invalidBackup()
        }
        // Never truncate the source or an existing destination on an invalid call.
        try Data().write(to: destination, options: .withoutOverwriting)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var rangeIndex = 0
        var consumedInRange: UInt64 = 0
        for segment in segments {
            try Task.checkCancellation()
            if let metadata = segment.metadata {
                try output.write(contentsOf: metadata)
                continue
            }
            var remaining = segment.audioLength!
            while remaining > 0 {
                try Task.checkCancellation()
                guard rangeIndex < audioRanges.count else { throw Self.invalidBackup() }
                let range = audioRanges[rangeIndex]
                let count = min(remaining, range.length - consumedInRange, 1_048_576)
                try input.seek(toOffset: range.offset + consumedInRange)
                let chunk = try input.read(upToCount: Int(count)) ?? Data()
                guard chunk.count == Int(count) else { throw Self.invalidBackup() }
                try output.write(contentsOf: chunk)
                remaining -= count
                consumedInRange += count
                if consumedInRange == range.length {
                    rangeIndex += 1
                    consumedInRange = 0
                }
            }
        }
        guard rangeIndex == audioRanges.count, try output.offset() == originalFileSize else {
            throw Self.invalidBackup()
        }
        try output.synchronize()
        completed = true
    }

    private init(version: Int, segments: [Segment], originalFileSize: UInt64, audioByteCount: UInt64) {
        self.version = version
        self.segments = segments
        self.originalFileSize = originalFileSize
        self.audioByteCount = audioByteCount
    }

    private func validate() throws {
        guard version == 1, originalFileSize > 0, audioByteCount > 0, !segments.isEmpty else {
            throw Self.invalidBackup()
        }
        var fileSize: UInt64 = 0
        var audioSize: UInt64 = 0
        for segment in segments {
            let count: UInt64
            switch (segment.metadata, segment.audioLength) {
            case (.some(let data), .none):
                guard !data.isEmpty else { throw Self.invalidBackup() }
                count = UInt64(data.count)
            case (.none, .some(let length)):
                guard length > 0, length <= audioByteCount - min(audioSize, audioByteCount) else {
                    throw Self.invalidBackup()
                }
                audioSize += length
                count = length
            default: throw Self.invalidBackup()
            }
            guard fileSize <= originalFileSize, count <= originalFileSize - fileSize else {
                throw Self.invalidBackup()
            }
            fileSize += count
        }
        guard fileSize == originalFileSize, audioSize == audioByteCount else { throw Self.invalidBackup() }
    }

    private static func validateRanges(_ ranges: [AudioPayloadRange], fileSize: UInt64) throws -> UInt64 {
        guard !ranges.isEmpty else { throw invalidBackup() }
        var previousEnd: UInt64 = 0
        var audioSize: UInt64 = 0
        for range in ranges {
            guard range.length > 0, range.offset >= previousEnd, range.offset <= fileSize,
                  range.length <= fileSize - range.offset else { throw invalidBackup() }
            previousEnd = range.offset + range.length
            // Ordered, disjoint ranges cannot total more than the file size.
            audioSize += range.length
        }
        return audioSize
    }

    private static func readMetadata(_ handle: FileHandle, offset: UInt64, length: UInt64) throws -> Data {
        guard length <= UInt64(Int.max) else { throw invalidBackup() }
        try handle.seek(toOffset: offset)
        var result = Data()
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, 1_048_576))
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard chunk.count == count else { throw invalidBackup() }
            result.append(chunk)
            remaining -= UInt64(count)
        }
        return result
    }

    private static func invalidBackup() -> MusTagError {
        .message(L10n.text("The metadata backup or audio layout is invalid. Nothing was changed.",
                          "元数据备份或音频结构无效，未修改任何文件。"))
    }
}
