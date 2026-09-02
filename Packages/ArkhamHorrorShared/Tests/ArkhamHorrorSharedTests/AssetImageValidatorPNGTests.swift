@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AssetImageValidatorTests {
    // MARK: - PNG chunk-order edge cases

    /// Builds a single, well-formed, CRC-valid PNG chunk of `type`
    /// carrying `payload`, exactly as ``AssetImageValidator``'s own chunk
    /// walk expects: a big-endian length, the 4-byte ASCII type, the
    /// payload, and a CRC-32 computed the same way
    /// (`CRC32.checksum(type + payload)`) production validation checks.
    private func chunk(_ type: String, _ payload: [UInt8] = []) -> [UInt8] {
        var bytes = [UInt8](withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        let typeAndPayload = Array(type.utf8) + payload
        bytes += typeAndPayload
        let crc = CRC32.checksum(Data(typeAndPayload))
        bytes += withUnsafeBytes(of: crc.bigEndian, Array.init)
        return bytes
    }

    /// Reads a big-endian `UInt32` chunk-length field from `bytes` at
    /// `offset`, matching how ``AssetImageValidator``'s own chunk walk
    /// reads it (avoiding `withUnsafeBytes`/`load`, which is not safely
    /// usable on an arbitrary, non-word-aligned array offset).
    private func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    @Test(
        """
        A real PNG with its single IDAT run split into two by an intervening, CRC-valid \
        ancillary chunk is rejected, even though every individual chunk's own CRC checks out
        """
    )
    func nonConsecutiveIDATRealFixtureRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        let idatTag: [UInt8] = Array("IDAT".utf8)
        guard let firstIDATStart = full.firstRange(of: idatTag) else {
            Issue.record("Fixture must contain an IDAT chunk")
            return
        }
        // The chunk header (length + type) starts 4 bytes before the type
        // tag itself.
        let chunkStart = firstIDATStart.lowerBound - 4
        let length = Int(readUInt32BE(full, at: chunkStart))
        let firstIDATChunkEnd = chunkStart + 4 + 4 + length + 4

        // Split the single real IDAT chunk into two independent, still
        // individually well-formed and CRC-valid IDAT chunks (each half of
        // the original compressed payload), with a real, CRC-valid `tEXt`
        // ancillary chunk spliced in between them. Every individual
        // chunk's own CRC-32 still checks out; only their relative order
        // is now spec-violating.
        let idatPayloadStart = chunkStart + 8
        let idatPayloadEnd = firstIDATChunkEnd - 4
        let idatPayload = Array(full[idatPayloadStart ..< idatPayloadEnd])
        let midpoint = idatPayload.count / 2
        let firstHalf = Array(idatPayload[..<midpoint])
        let secondHalf = Array(idatPayload[midpoint...])

        var mutated = Array(full[..<chunkStart])
        mutated += chunk("IDAT", firstHalf)
        mutated += chunk("tEXt", Array("k\0v".utf8))
        mutated += chunk("IDAT", secondHalf)
        mutated += Array(full[firstIDATChunkEnd...])

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test(
        "A real PNG with a genuinely consecutive IDAT split (no interposed chunk) still validates"
    )
    func consecutiveIDATSplitRealFixtureAccepted() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        let idatTag: [UInt8] = Array("IDAT".utf8)
        guard let firstIDATStart = full.firstRange(of: idatTag) else {
            Issue.record("Fixture must contain an IDAT chunk")
            return
        }
        let chunkStart = firstIDATStart.lowerBound - 4
        let length = Int(readUInt32BE(full, at: chunkStart))
        let firstIDATChunkEnd = chunkStart + 4 + 4 + length + 4
        let idatPayloadStart = chunkStart + 8
        let idatPayloadEnd = firstIDATChunkEnd - 4
        let idatPayload = Array(full[idatPayloadStart ..< idatPayloadEnd])
        let midpoint = idatPayload.count / 2
        let firstHalf = Array(idatPayload[..<midpoint])
        let secondHalf = Array(idatPayload[midpoint...])

        var mutated = Array(full[..<chunkStart])
        mutated += chunk("IDAT", firstHalf)
        mutated += chunk("IDAT", secondHalf)
        mutated += Array(full[firstIDATChunkEnd...])

        let metadata = try AssetImageValidator.validate(
            data: Data(mutated),
            declaredContentType: nil,
            expectedFormat: .png,
            limits: limits
        )
        #expect(metadata.width == 4)
        #expect(metadata.height == 4)
    }
}
