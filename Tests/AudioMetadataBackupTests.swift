import Foundation
import XCTest
@testable import MusTag

final class AudioMetadataBackupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testArchiveOmitsAudioBytesAndRestoresAcrossDifferentRangeBoundaries() throws {
        let firstAudio = Data(repeating: 0xa5, count: 2 * 1_024 * 1_024)
        let secondAudio = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024)
        let original = Data("head".utf8) + firstAudio + Data("middle".utf8) + secondAudio + Data("tail".utf8)
        let source = try write(original, name: "original")
        let backup = try AudioMetadataBackup.capture(from: source, audioRanges: [
            (4, UInt64(firstAudio.count)), (UInt64(10 + firstAudio.count), UInt64(secondAudio.count))
        ])
        let data = try backup.encodedData()
        XCTAssertLessThan(data.count, 1_024, "Audio must never be serialized into the metadata archive")
        XCTAssertEqual(backup.audioByteCount, 4 * 1_024 * 1_024)
        XCTAssertEqual(backup.originalFileSize, UInt64(original.count))

        let current = Data("new".utf8) + firstAudio.prefix(17) + Data("split".utf8)
            + firstAudio.dropFirst(17) + secondAudio + Data("new trailer".utf8)
        let edited = try write(current, name: "edited")
        let destination = root.appendingPathComponent("restored")
        try AudioMetadataBackup(data: data).restore(from: edited, audioRanges: [
            (3, 17), (25, UInt64(firstAudio.count + secondAudio.count - 17))
        ], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: edited), current)
    }

    func testCaptureRejectsEmptyOverlappingUnsortedAndOutOfBoundsAudioRanges() throws {
        let source = try write(Data(repeating: 1, count: 20), name: "source")
        let invalidRanges: [[AudioPayloadRange]] = [
            [], [(1, 0)], [(2, 10), (11, 2)], [(8, 2), (1, 2)],
            [(19, 2)], [(UInt64.max, 2)], [(0, UInt64.max)]
        ]
        for ranges in invalidRanges {
            XCTAssertThrowsError(try AudioMetadataBackup.capture(from: source, audioRanges: ranges))
        }
    }

    func testUnsupportedVersionAndMalformedSegmentsAreRejected() throws {
        let source = try write(Data("tagsAUDIOend".utf8), name: "source")
        let data = try AudioMetadataBackup.capture(from: source, audioRanges: [(4, 5)]).encodedData()
        let valid = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        var mutations: [[String: Any]] = []
        var changed = valid
        changed["version"] = 2
        mutations.append(changed)
        changed = valid
        changed["audioByteCount"] = 6
        mutations.append(changed)
        changed = valid
        changed["originalFileSize"] = 1
        mutations.append(changed)
        changed = valid
        changed["segments"] = [["metadata": Data([1]), "audioLength": 5]]
        mutations.append(changed)
        changed = valid
        changed["segments"] = [["audioLength": 0]]
        mutations.append(changed)
        changed = valid
        changed["segments"] = []
        mutations.append(changed)
        for archive in mutations {
            let malformed = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            XCTAssertThrowsError(try AudioMetadataBackup(data: malformed))
        }
        XCTAssertThrowsError(try AudioMetadataBackup(data: Data("not a backup".utf8)))
    }

    func testRestoreRejectsWrongAudioLengthWithoutCreatingDestination() throws {
        let source = try write(Data("tagsAUDIOend".utf8), name: "source")
        let backup = try AudioMetadataBackup.capture(from: source, audioRanges: [(4, 5)])
        let destination = root.appendingPathComponent("restored")
        XCTAssertThrowsError(try backup.restore(from: source, audioRanges: [(4, 4)], to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreNeverOverwritesAnExistingDestinationOrSource() throws {
        let original = Data("tagsAUDIOend".utf8)
        let source = try write(original, name: "source")
        let backup = try AudioMetadataBackup.capture(from: source, audioRanges: [(4, 5)])
        let existing = try write(Data("do not overwrite".utf8), name: "existing")
        XCTAssertThrowsError(try backup.restore(from: source, audioRanges: [(4, 5)], to: source))
        XCTAssertThrowsError(try backup.restore(from: source, audioRanges: [(4, 5)], to: existing))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: existing), Data("do not overwrite".utf8))
    }

    func testM4ARangesIncludeOnlyMdatContents() throws {
        let first = Data("first audio".utf8)
        let second = Data("second audio".utf8)
        let original = atom("ftyp", Data("M4A ".utf8)) + atom("mdat", first)
            + atom("free", Data(repeating: 0, count: 20)) + atom("mdat", second)
            + atom("moov", Data("container".utf8))
        let source = try write(original, name: "multiple.m4a")
        let ranges = try NativeAudio.payloadRanges(url: source)
        XCTAssertEqual(ranges.map(\.length), [UInt64(first.count), UInt64(second.count)])
        let backup = try AudioMetadataBackup.capture(from: source, audioRanges: ranges)
        let destination = root.appendingPathComponent("restored.m4a")
        try backup.restore(from: source, audioRanges: ranges, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func atom(_ type: String, _ data: Data) -> Data {
        let length = UInt32(data.count + 8)
        return Data([UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                     UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]) + Data(type.utf8) + data
    }
}
