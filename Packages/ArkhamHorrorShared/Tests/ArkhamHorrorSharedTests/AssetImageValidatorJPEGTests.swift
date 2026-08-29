@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AssetImageValidatorTests {
    // MARK: - JPEG marker walk / SOF segment edge cases

    @Test("A JPEG truncated mid-marker-walk is rejected as malformed, not a crash")
    func truncatedJPEGRejected() throws {
        // SOI + an APP0 marker whose length bytes never arrive: long enough
        // to clear the SOI signature check, but truncated inside the
        // marker-segment walk (not the initial 4-byte signature check).
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: self.limits
            )
        }
    }

    @Test("A JPEG with only the SOI marker present is malformed, not a signature mismatch")
    func jpegTruncatedImmediatelyAfterSOIRejectedAsMalformed() throws {
        // Only the 2-byte SOI marker (FF D8) is present: this matches the
        // JPEG signature, so it must not be classified as
        // `signatureMismatch` (which is reserved for data that does not
        // look like a JPEG at all). There isn't enough data to walk even
        // one marker segment, so it should be `malformedImageData`.
        for data in [Data([0xFF, 0xD8]), Data([0xFF, 0xD8, 0xFF])] {
            #expect(throws: AssetError.malformedImageData) {
                _ = try AssetImageValidator.validate(
                    data: data,
                    declaredContentType: nil,
                    expectedFormat: .jpeg,
                    limits: self.limits
                )
            }
        }
    }

    @Test(
        """
        A JPEG SOF segment whose declared length is too short for its own \
        precision/height/width fields is rejected, even though plausible \
        extra bytes happen to follow it in the buffer
        """
    )
    func jpegSOFSegmentDeclaredLengthTooShortRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0 marker
        // A declared segment length of 4: after its own 2 length bytes,
        // only 2 payload bytes remain — nowhere near the 5 bytes needed
        // for precision (1) + height (2) + width (2).
        bytes += [0x00, 0x04]
        bytes += [0x08, 0x00]
        // Bytes that a naive "does this stay within the whole buffer"
        // check (ignoring the segment's own declared length) could
        // mistake for the rest of a plausible height/width, if the
        // segment-length guard were absent.
        bytes += [0x00, 0x10, 0x00, 0x20, 0x00, 0x30]
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test(
        """
        A JPEG SOF segment declaring just enough length for precision/height/width but no \
        component count or descriptor is rejected, not accepted on plausible dimensions alone
        """
    )
    func jpegSOFSegmentMissingComponentDescriptorRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0 marker
        // A declared segment length of 7: enough for the length field
        // itself (2) + precision (1) + height (2) + width (2), but with
        // no room at all for the mandatory 1-byte component count or any
        // 3-byte component descriptor. A real SOF segment needs at least
        // 11 declared bytes to include those fields.
        bytes += [0x00, 0x07]
        bytes += [0x08, 0x00, 0x10, 0x00, 0x20]
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test(
        "A JPEG SOF segment with exactly the minimum valid length (one component) is accepted"
    )
    func jpegSOFSegmentExactMinimumLengthAccepted() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0 marker
        // A declared segment length of 11: length field (2) + precision
        // (1) + height (2) + width (2) + component count (1) + exactly
        // one 3-byte component descriptor — the smallest valid SOF.
        bytes += [0x00, 0x0B]
        bytes += [0x08] // precision
        bytes += [0x00, 0x09] // height = 9
        bytes += [0x00, 0x06] // width = 6
        bytes += [0x01] // component count = 1
        bytes += [0x01, 0x11, 0x00] // one component descriptor
        bytes += [0xFF, 0xDA] // SOS marker
        bytes += [0x00, 0x08] // SOS header length = 8
        bytes += [0x01] // Ns = 1 component in this scan
        bytes += [0x01, 0x00] // component selector, DC/AC table selector
        bytes += [0x00, 0x3F, 0x00] // Ss, Se, AhAl
        bytes += [0x00] // one byte of entropy-coded scan data
        bytes += [0xFF, 0xD9] // EOI
        let metadata = try AssetImageValidator.validate(
            data: Data(bytes),
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 6)
        #expect(metadata.height == 9)
    }

    @Test(
        "A JPEG SOS segment immediately followed by EOI (zero entropy-coded bytes) is rejected"
    )
    func jpegZeroEntropyScanDataRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0 marker
        bytes += [0x00, 0x0B] // length = 11
        bytes += [0x08] // precision
        bytes += [0x00, 0x09] // height = 9
        bytes += [0x00, 0x06] // width = 6
        bytes += [0x01] // component count = 1
        bytes += [0x01, 0x11, 0x00] // one component descriptor
        bytes += [0xFF, 0xDA] // SOS marker
        bytes += [0x00, 0x08] // SOS header length = 8
        bytes += [0x01] // Ns = 1 component in this scan
        bytes += [0x01, 0x00] // component selector, DC/AC table selector
        bytes += [0x00, 0x3F, 0x00] // Ss, Se, AhAl
        // No entropy-coded scan data bytes at all: the real marker below
        // (EOI) begins immediately after the SOS header, unlike
        // `jpegSOFSegmentExactMinimumLengthAccepted`'s one real byte.
        bytes += [0xFF, 0xD9] // EOI
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test(
        """
        A real, complete JPEG with its entropy-coded scan data byte-stuffed to zero length \
        (SOS directly followed by EOI, mutated from a genuinely decodable fixture) is rejected
        """
    )
    func jpegRealFixtureWithScanDataRemovedIsRejected() throws {
        let bytes = [UInt8](AssetImageFixtureBuilder.validJPEG(width: 4, height: 4))
        // The real fixture's terminal EOI marker is unconditionally its
        // last two bytes; find the SOS marker and splice the EOI directly
        // after its own header, deleting every real entropy-coded byte
        // in between.
        guard let sosStart = bytes.firstRange(of: [0xFF, 0xDA]) else {
            Issue.record("Fixture must contain an SOS marker")
            return
        }
        let sosHeaderLength = Int(bytes[sosStart.upperBound]) << 8
            | Int(bytes[sosStart.upperBound + 1])
        let scanHeaderEnd = sosStart.upperBound + sosHeaderLength
        let eoi: [UInt8] = [0xFF, 0xD9]
        let mutated = bytes[..<scanHeaderEnd] + eoi
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }
}
