import AVFoundation
import XCTest
@testable import MusTag

final class NativeAudioTests: XCTestCase {
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
}
