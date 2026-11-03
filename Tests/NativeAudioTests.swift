import AVFoundation
import UIKit
import XCTest
@testable import MusTag

final class NativeAudioTests: XCTestCase {
    func testCoverRoundTripAndReplacementPreserveTagsAndAudioInEveryFormat() throws {
        let first = try artwork(color: .red, jpeg: false)
        let replacement = try artwork(color: .blue, jpeg: true)
        for ext in ["mp3", "flac", "m4a"] {
            let copy = try audioCopy(ext)
            defer { try? FileManager.default.removeItem(at: copy) }
            let codec = NativeMetadataCodec()
            let before = try NativeAudio.payloadHash(url: copy)
            let originalTags = try codec.read(from: copy).tags
            try codec.writeArtwork(first, to: copy)
            XCTAssertEqual(try codec.read(from: copy).artwork, first, ext)
            XCTAssertEqual(try codec.read(from: copy).tags, originalTags, ext)
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), before, ext)

            var tags = originalTags
            tags.title = "Cover preserved during text edit"
            try codec.write(tags, to: copy)
            XCTAssertEqual(try codec.read(from: copy).artwork, first, ext)

            try codec.writeArtwork(replacement, to: copy)
            XCTAssertEqual(try codec.read(from: copy).artwork, replacement, ext)
            XCTAssertEqual(try codec.read(from: copy).tags, tags, ext)
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), before, ext)
            XCTAssertNil(try Data(contentsOf: copy).range(of: first.data), "Old front cover must be replaced, not accumulated: \(ext)")
        }
    }

    func testInvalidCoverCannotChangeAudioFile() throws {
        let valid = try artwork(color: .red, jpeg: false)
        let invalid = [
            AudioArtwork(data: Data("not an image".utf8), mimeType: "image/png"),
            AudioArtwork(data: valid.data, mimeType: "image/jpeg"),
            AudioArtwork(data: Data(repeating: 0, count: 8 * 1024 * 1024 + 1), mimeType: "image/png")
        ]
        for ext in ["mp3", "flac", "m4a"] {
            let copy = try audioCopy(ext)
            defer { try? FileManager.default.removeItem(at: copy) }
            let before = try Data(contentsOf: copy)
            for image in invalid {
                XCTAssertThrowsError(try NativeMetadataCodec().writeArtwork(image, to: copy), ext)
                XCTAssertEqual(try Data(contentsOf: copy), before, ext)
            }
        }
    }

    func testCoverOnlySaveBacksUpAndRestoresExactOriginalBytesInEveryFormat() async throws {
        let originalArtwork = try artwork(color: .red, jpeg: false)
        let replacement = try artwork(color: .blue, jpeg: true)
        for ext in ["mp3", "flac", "m4a"] {
            let copy = try audioCopy(ext)
            let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.removeItem(at: state)
            }
            let codec = NativeMetadataCodec()
            try codec.writeArtwork(originalArtwork, to: copy)
            let originalBytes = try Data(contentsOf: copy)
            let payload = try NativeAudio.payloadHash(url: copy)
            let store = AudioFileStore(codec: codec, storageDirectory: state)
            let imported = try await store.importFiles(from: [copy])
            var document = try XCTUnwrap(imported.documents.first, imported.failures.joined(separator: "; "))
            XCTAssertEqual(document.originalArtwork, originalArtwork, ext)
            document.draftArtwork = replacement
            XCTAssertTrue(document.hasChanges, ext)
            let (saved, backup) = try await store.save(document)
            XCTAssertFalse(saved.hasChanges, ext)
            XCTAssertEqual(saved.originalArtwork, replacement, ext)
            XCTAssertEqual(try codec.read(from: copy).artwork, replacement, ext)
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), payload, ext)
            XCTAssertEqual(try Data(contentsOf: backup.backupURL), originalBytes, ext)
            let restored = try await store.restore(backup)
            XCTAssertEqual(restored.originalArtwork, originalArtwork, ext)
            XCTAssertEqual(restored.draftArtwork, originalArtwork, ext)
            XCTAssertFalse(restored.hasChanges, ext)
            XCTAssertEqual(try Data(contentsOf: copy), originalBytes, ext)
        }
    }

    func testMP3CoverReplacementPreservesBackCoverAndPrefersFront() throws {
        let copy = try audioCopy("mp3")
        defer { try? FileManager.default.removeItem(at: copy) }
        var audio = try Data(contentsOf: copy)
        if audio.starts(with: Data("ID3".utf8)), audio.count >= 10 {
            let tagSize = audio[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            audio.removeFirst(10 + tagSize + (audio[5] & 0x10 != 0 ? 10 : 0))
        }
        let back = try artwork(color: .green, jpeg: false)
        var body = Data([0]) // ISO-8859-1 encoding, MIME, back-cover type, empty description.
        body.append(Data("image/png".utf8))
        body.append(contentsOf: [0, 4, 0])
        body.append(back.data)
        var frame = Data("APIC".utf8)
        frame.append(syncSafe(body.count))
        frame.append(contentsOf: [0, 0])
        frame.append(body)
        var file = Data([73, 68, 51, 4, 0, 0])
        file.append(syncSafe(frame.count))
        file.append(frame)
        file.append(audio)
        try file.write(to: copy)
        let codec = NativeMetadataCodec()
        XCTAssertEqual(try codec.read(from: copy).artwork, back)
        let before = try NativeAudio.payloadHash(url: copy)
        for front in [try artwork(color: .red, jpeg: false), try artwork(color: .blue, jpeg: true)] {
            try codec.writeArtwork(front, to: copy)
            XCTAssertEqual(try codec.read(from: copy).artwork, front)
            XCTAssertNotNil(try Data(contentsOf: copy).range(of: back.data))
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), before)
        }
    }

    func testTagEditingPreservesEncodedAudioInEverySupportedFormat() throws {
        for ext in ["mp3", "flac", "m4a"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: ext, subdirectory: "Fixtures"))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent("track.\(ext)")
            try FileManager.default.copyItem(at: source, to: copy)
            let codec = NativeMetadataCodec()
            let before = try NativeAudio.payloadHash(url: copy)
            var tags = try codec.read(from: copy).tags
            tags.title = "夜曲 · Nocturne 🎵"
            tags.artist = "MusTag Test Artist"
            tags.album = "Metadata round trip"
            tags.albumArtist = "Album Artist"
            tags.year = "2026"
            tags.trackNumber = "3"
            tags.discNumber = "1"
            tags.genre = "Classical"
            try codec.write(tags, to: copy)
            XCTAssertEqual(try codec.read(from: copy).tags, tags, ext)
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), before, ext)
            tags.title = ""
            try codec.write(tags, to: copy)
            XCTAssertEqual(try codec.read(from: copy).tags.title, "", ext)
            XCTAssertEqual(try NativeAudio.payloadHash(url: copy), before, ext)
        }
    }

    func testMalformedContainerCannotBeApprovedForWriting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 0, 0, 1, 109, 100, 97, 116]).write(to: url)
        XCTAssertThrowsError(try NativeAudio.payloadHash(url: url))
        let truncated = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "truncated", withExtension: "mp3", subdirectory: "Fixtures"))
        XCTAssertThrowsError(try NativeAudio.payloadHash(url: truncated))
    }

    func testUnknownID3FrameSurvivesAndDiscardOnEditFrameIsRejected() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp3", subdirectory: "Fixtures"))
        let audio = try Data(contentsOf: source)
        for discard: UInt8 in [0, 0x40] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
            defer { try? FileManager.default.removeItem(at: url) }
            let opaque = Data("private metadata".utf8)
            var frame = Data("ZZZZ".utf8)
            frame.append(contentsOf: [0, 0, 0, UInt8(opaque.count), discard, 0])
            frame.append(opaque)
            var fixture = Data([73, 68, 51, 4, 0, 0, 0, 0, 0, UInt8(frame.count)])
            fixture.append(frame)
            fixture.append(audio)
            try fixture.write(to: url)
            let codec = NativeMetadataCodec()
            var tags = try codec.read(from: url).tags
            tags.title = "Preserve other fields"
            if discard != 0 {
                XCTAssertThrowsError(try codec.write(tags, to: url))
                XCTAssertThrowsError(try codec.writeArtwork(artwork(color: .red, jpeg: false), to: url))
                XCTAssertEqual(try Data(contentsOf: url), fixture)
            } else {
                let before = try NativeAudio.payloadHash(url: url)
                try codec.write(tags, to: url)
                XCTAssertNotNil(try Data(contentsOf: url).range(of: frame))
                XCTAssertEqual(try NativeAudio.payloadHash(url: url), before)
            }
        }
    }

    func testRealChromaprintIsDeterministicAndUsesFullDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 20))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) {
            let frequency = 220.0 + Double((i / 22050) % 12) * 55
            samples[i] = Float(sin(Double(i) * frequency * 2 * .pi / 44100) * 0.5)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let first = try await NativeAudio.fingerprint(url: url)
        let second = try await NativeAudio.fingerprint(url: url)
        XCTAssertGreaterThan(first.fingerprint.count, 20)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.duration, 20, accuracy: 0.01)
    }

    private func audioCopy(_ ext: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: ext, subdirectory: "Fixtures"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func artwork(color: UIColor, jpeg: Bool) throws -> AudioArtwork {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
        return AudioArtwork(data: try XCTUnwrap(jpeg ? image.jpegData(compressionQuality: 0.9) : image.pngData()),
                            mimeType: jpeg ? "image/jpeg" : "image/png")
    }

    private func syncSafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7f), UInt8((value >> 14) & 0x7f),
              UInt8((value >> 7) & 0x7f), UInt8(value & 0x7f)])
    }
}
