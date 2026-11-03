import AVFoundation
import CryptoKit
import Foundation

enum NativeAudio {
    /// Local staged file only. Decode at most 120 seconds; duration describes the full file.
    static func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Double) {
        let worker = Task.detached(priority: .userInitiated) { () throws -> (String, Double) in
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let format = file.processingFormat
            guard format.sampleRate > 0, format.channelCount > 0,
                  let context = chromaprint_new(Int32(CHROMAPRINT_ALGORITHM_DEFAULT.rawValue)) else {
                throw MusTagError.message(L10n.text("Cannot decode this audio file.", "无法解码此音频文件。"))
            }
            defer { chromaprint_free(context) }
            guard chromaprint_start(context, Int32(format.sampleRate), Int32(format.channelCount)) == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw MusTagError.message(L10n.text("Cannot start fingerprinting.", "无法开始计算指纹。"))
            }
            let limit = min(file.length, AVAudioFramePosition(format.sampleRate * 120))
            while file.framePosition < limit {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, limit - file.framePosition)))
                guard buffer.frameLength > 0 else { break }
                guard let samples = buffer.int16ChannelData?[0],
                      chromaprint_feed(context, samples, Int32(buffer.frameLength * format.channelCount)) == 1 else {
                    throw MusTagError.message(L10n.text("Fingerprint calculation failed.", "指纹计算失败。"))
                }
            }
            var encoded: UnsafeMutablePointer<CChar>?
            guard chromaprint_finish(context) == 1, chromaprint_get_fingerprint(context, &encoded) == 1,
                  let encoded else {
                throw MusTagError.message(L10n.text("Not enough audio to identify.", "音频过短，无法识别。"))
            }
            defer { chromaprint_dealloc(encoded) }
            return (String(cString: encoded), Double(file.length) / format.sampleRate)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() })
    }

    /// Hash encoded audio, not tags or container offsets. Streams chunks to bound memory.
    static func payloadHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var ranges: [(UInt64, UInt64)] = []
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalidAudio() }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw invalidAudio() }
            return data
        }
        func uint(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
        switch url.pathExtension.lowercased() {
        case "mp3":
            let range = try MTTagBridge.mpegRange(url: url)
            ranges = [(range[0].uint64Value, range[1].uint64Value)]
        case "flac":
            var offset: UInt64 = 0
            if try read(0, 3) == Data("ID3".utf8) {
                let id3 = try read(0, 10)
                guard id3[6...9].allSatisfy({ $0 < 128 }) else { throw invalidAudio() }
                offset = 10 + id3[6...9].reduce(UInt64(0)) { ($0 << 7) | UInt64($1) }
                if id3[3] == 4 && id3[5] & 0x10 != 0 { offset += 10 }
            }
            guard try read(offset, 4) == Data("fLaC".utf8) else { throw invalidAudio() }
            offset += 4
            var last = false
            while !last {
                let header = try read(offset, 4)
                last = header[0] & 0x80 != 0
                offset += 4 + uint(header.subdata(in: 1..<4))
                guard offset <= size else { throw invalidAudio() }
            }
            var end = size
            if size >= 128, try read(size - 128, 3) == Data("TAG".utf8) { end -= 128 }
            guard end > offset else { throw invalidAudio() }
            ranges = [(offset, end - offset)]
        case "m4a", "mp4":
            var offset: UInt64 = 0
            while offset < size {
                let header = try read(offset, 8)
                var length = uint(header.prefix(4))
                var headerSize: UInt64 = 8
                if length == 1 { length = uint(try read(offset + 8, 8)); headerSize = 16 }
                if length == 0 { length = size - offset }
                guard length >= headerSize, length <= size - offset else { throw invalidAudio() }
                if header.subdata(in: 4..<8) == Data("mdat".utf8), length > headerSize {
                    ranges.append((offset + headerSize, length - headerSize))
                }
                offset += length
            }
        default: throw invalidAudio()
        }
        guard !ranges.isEmpty else { throw invalidAudio() }
        var hasher = SHA256()
        for (offset, length) in ranges {
            guard offset <= size, length <= size - offset else { throw invalidAudio() }
            try handle.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
                guard !chunk.isEmpty else { throw invalidAudio() }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func invalidAudio() -> MusTagError {
        .message(L10n.text("Cannot verify the audio payload. The original file was not modified.",
                          "无法校验音频数据，未修改原文件。"))
    }
}
