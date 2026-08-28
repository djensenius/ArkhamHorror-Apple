@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ContractRevision")
struct ContractRevisionTests {
    // MARK: - Numeric ordering

    @Test("Numeric ordering: 0.1.9 is less than 0.1.11")
    func numericOrdering() throws {
        let patchNine = try ContractRevision("0.1.9")
        let patchEleven = try ContractRevision("0.1.11")
        #expect(patchNine < patchEleven)
        #expect(!(patchEleven < patchNine))
        #expect(patchNine != patchEleven)
    }

    @Test("Equal revisions compare equal and are not less-than")
    func equalRevisions() throws {
        let revA = try ContractRevision("0.1.11")
        let revB = try ContractRevision("0.1.11")
        #expect(revA == revB)
        #expect(!(revA < revB))
        #expect(!(revB < revA))
    }

    @Test("Major component takes precedence over minor and patch")
    func majorPrecedence() throws {
        let lowerMajor = try ContractRevision("1.99.99")
        let higherMajor = try ContractRevision("2.0.0")
        #expect(lowerMajor < higherMajor)
    }

    @Test("Minor component takes precedence over patch")
    func minorOverPatch() throws {
        let highPatch = try ContractRevision("0.1.99")
        let nextMinor = try ContractRevision("0.2.0")
        #expect(highPatch < nextMinor)
    }

    @Test("Zero revision parses and compares correctly")
    func zeroRevision() throws {
        let zero = try ContractRevision("0.0.0")
        #expect(zero.major == 0)
        #expect(zero.minor == 0)
        #expect(zero.patch == 0)
        #expect(!(zero < zero))
    }

    // MARK: - Malformed input

    @Test(
        "Non-ASCII-digit and structurally invalid strings are rejected",
        arguments: [
            // structural
            "1.0",
            "1.0.0.0",
            "a.b.c",
            "1.x.0",
            "0.1.11extra",
            "",
            ".",
            "0.1.",
            ".1.0",
            // overflow
            "99999999999999999999.0.0",
            // sign characters (rejected by strict ASCII digit check)
            "-1.0.0",
            "0.-1.0",
            "0.0.-1",
            "+1.0.0",
            "0.+1.0",
            // whitespace
            " 1.0.0",
            "1.0.0 ",
            "1. 0.0",
            // Unicode decimal digits (not ASCII 0–9)
            "١.٠.٠",
        ]
    )
    func rejectsMalformed(input: String) {
        #expect(throws: ContractRevisionError.malformed) {
            try ContractRevision(input)
        }
    }

    // MARK: - String round-trip

    @Test("Description round-trips through init")
    func descriptionRoundTrips() throws {
        let rev = try ContractRevision("0.1.11")
        #expect(rev.description == "0.1.11")
        #expect(try ContractRevision(rev.description) == rev)
    }

    // MARK: - Literal factory

    @Test("Literal factory produces correct components")
    func literalFactory() {
        let rev = ContractRevision.literal(major: 0, minor: 1, patch: 11)
        #expect(rev.major == 0)
        #expect(rev.minor == 1)
        #expect(rev.patch == 11)
        #expect(rev == (try? ContractRevision("0.1.11")))
    }

    @Test("Literal factory accepts the full unsigned range without conversion traps")
    func literalFactoryFullRange() {
        let rev = ContractRevision.literal(major: .max, minor: .max, patch: .max)
        #expect(rev.major == .max)
        #expect(rev.minor == .max)
        #expect(rev.patch == .max)
    }

    // MARK: - Codable

    @Test("JSON decoding from dot-separated string")
    func jsonDecoding() throws {
        let data = Data(#""0.1.12""#.utf8)
        let decoded = try JSONDecoder().decode(ContractRevision.self, from: data)
        #expect(decoded == ContractRevision.literal(major: 0, minor: 1, patch: 12))
    }

    @Test("JSON encoding produces dot-separated string")
    func jsonEncoding() throws {
        let rev = ContractRevision.literal(major: 0, minor: 1, patch: 12)
        let data = try JSONEncoder().encode(rev)
        #expect(String(data: data, encoding: .utf8) == #""0.1.12""#)
    }

    @Test("JSON decoding rejects a malformed revision string")
    func jsonDecodingMalformed() {
        let data = Data(#""not.a.version""#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContractRevision.self, from: data)
        }
    }
}
