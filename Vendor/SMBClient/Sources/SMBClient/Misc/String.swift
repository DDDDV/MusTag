import Foundation

extension String {
  func encoded() -> Data {
    // SMB strings are UTF-16LE without a byte-order mark.
    Data(utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
  }
}
