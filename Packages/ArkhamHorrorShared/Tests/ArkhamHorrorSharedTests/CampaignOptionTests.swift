@testable import ArkhamHorrorShared
import Foundation
import Testing

/// CampaignOption's known-flag, unknown-flag, and CampaignVariant decode/encode
/// behavior. Split out of `GameLifecycleTests` purely to stay under SwiftLint's
/// type-length limit.
@Suite("CampaignOption")
struct CampaignOptionTests {
    @Test("A known campaign option flag decodes to .flag, never .unknown")
    func knownFlagDecodes() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "PerformIntro"}"#.utf8)
        )
        #expect(decoded == .flag(.performIntro))
    }

    @Test(
        "A genuinely unrecognized tag decodes to .unknown, never silently treated as a known flag"
    )
    func unrecognizedTagDecodesToUnknown() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "SomeFutureFlagNotYetKnown"}"#.utf8)
        )
        guard case let .unknown(tag, _) = decoded else {
            Issue.record("Expected .unknown, got \(decoded)")
            return
        }
        #expect(tag == "SomeFutureFlagNotYetKnown")
    }

    @Test("CampaignVariant decodes its string contents")
    func campaignVariantDecodes() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "CampaignVariant", "contents": "return-to"}"#.utf8)
        )
        #expect(decoded == .campaignVariant("return-to"))
    }

    @Test("CampaignVariant with null contents throws, rather than accepting a null string")
    func campaignVariantNullContentsThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CampaignOption.self,
                from: Data(#"{"tag": "CampaignVariant", "contents": null}"#.utf8)
            )
        }
    }

    @Test("CampaignOptionFlag(rawValue:) rejects an unrecognized flag string outright")
    func unknownFlagStringIsUnconstructible() {
        #expect(CampaignOptionFlag(rawValue: "FutureOption") == nil)
    }

    @Test("An unknown CampaignOption preserves its full raw object, including additive keys")
    func unknownOptionPreservesRawObject() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(
                #"{"tag": "SomeFutureFlagNotYetKnown", "contents": null, "extra": 1}"#.utf8
            )
        )
        guard case let .unknown(tag, rawObject) = decoded else {
            Issue.record("Expected .unknown, got \(decoded)")
            return
        }
        #expect(tag == "SomeFutureFlagNotYetKnown")
        guard case let .object(fields) = rawObject else {
            Issue.record("Expected .object rawObject, got \(rawObject)")
            return
        }
        #expect(fields["contents"] == .null)
        #expect(fields["extra"] == .number(.integer(1)))
    }

    @Test("An unknown CampaignOption can never be encoded (never resubmittable)")
    func unknownOptionCannotBeEncoded() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "SomeFutureFlagNotYetKnown"}"#.utf8)
        )
        #expect(throws: CampaignOptionError.cannotEncodeUnknownTag("SomeFutureFlagNotYetKnown")) {
            try JSONEncoder().encode(decoded)
        }
    }
}
