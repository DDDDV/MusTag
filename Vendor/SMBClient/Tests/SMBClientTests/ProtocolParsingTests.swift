import XCTest
@testable import SMBClient

final class ProtocolParsingTests: XCTestCase {
  func testAVPairPreservesKnownIdentifiersAndValues() throws {
    for rawValue in UInt16(0)...10 {
      let avId = try XCTUnwrap(AVPair.AVId(rawValue: rawValue))
      let original = AVPair(avId: avId, avValue: rawValue == 0 ? Data() : Data([1, 2, 3, 4]))
      let decoded = try XCTUnwrap(AVPair(data: original.encoded()))
      XCTAssertEqual(decoded.avId, avId)
      XCTAssertEqual(decoded.avLen, original.avLen)
      XCTAssertEqual(decoded.avValue, original.avValue)
      XCTAssertEqual(decoded.encoded(), original.encoded())
    }
  }

  func testAVPairRejectsUnknownIdentifiersAndTruncatedPayloads() {
    for bytes: [UInt8] in [[], [1], [1, 0], [1, 0, 0], [255, 255, 0, 0], [1, 0, 2, 0, 65]] {
      XCTAssertNil(AVPair(data: Data(bytes)))
    }
  }

  func testDirectoryResponseWithNoEntriesIsEmpty() {
    XCTAssertTrue(response(buffer: Data()).files().isEmpty)
  }

  func testDirectoryResponseStopsAtFinalEntry() {
    let buffer = entry(nameBytes: [0x41, 0], nextOffset: 0)
    XCTAssertEqual(response(buffer: buffer).files().map(\.fileName), ["A"])
  }

  func testDirectoryResponsePreservesMultipleEntriesAndUnicodeNames() {
    let first = entry(nameBytes: [0x41, 0], nextOffset: 72)
    let second = entry(nameBytes: [0xf3, 0x97, 0x50, 0x4e], nextOffset: 0)
    let files = response(buffer: first + second).files()
    XCTAssertEqual(files.map(\.fileName), ["A", "音乐"])
    XCTAssertEqual(files.map(\.nextEntryOffset), [72, 0])
  }

  private func response(buffer: Data) -> QueryDirectory.Response {
    // 64-byte SMB header, then the 8-byte query-directory response header.
    var packet = Data(count: 64)
    packet.append(contentsOf: [9, 0, 72, 0])
    appendUInt32(UInt32(buffer.count), to: &packet)
    packet.append(buffer)
    return QueryDirectory.Response(data: packet)
  }

  private func entry(nameBytes: [UInt8], nextOffset: UInt32) -> Data {
    var data = Data()
    appendUInt32(nextOffset, to: &data)
    data.append(Data(count: 56))
    appendUInt32(UInt32(nameBytes.count), to: &data)
    data.append(contentsOf: nameBytes)
    if nextOffset > 0 {
      data.append(Data(count: Int(nextOffset) - data.count))
    }
    return data
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
}
