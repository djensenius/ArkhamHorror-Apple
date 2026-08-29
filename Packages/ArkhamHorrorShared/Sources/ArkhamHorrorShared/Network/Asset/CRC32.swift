import Foundation

/// A pure-Swift, table-based CRC-32 (IEEE 802.3 polynomial, the same
/// algorithm PNG's own spec mandates for every chunk's trailing checksum)
/// — implemented directly rather than importing system `zlib`, so this
/// package depends on no C library whose module map or availability could
/// differ subtly across this package's four Apple deployment platforms.
/// Verified against the standard reference test vector
/// (`CRC32("123456789") == 0xCBF43926`) in ``CRC32Tests``.
enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    /// The CRC-32 checksum of `data`, computed over its bytes in order.
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
