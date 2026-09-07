@testable import ArkhamHorrorShared
import Testing

@Suite("AssetIdentifier grammars")
struct AssetIdentifierTests {
    // MARK: - cardCode

    @Test(
        "Valid card codes are accepted",
        arguments: [
            "01", "01001", "999999", "01001a", "01001bb", "x05184", "xbetween",
            "04105_Mutated1", "04105_Mutated21", "04105_Mutated999",
        ]
    )
    func validCardCodesAccepted(raw: String) throws {
        let identifier = try AssetIdentifier.cardCode(raw)
        #expect(identifier.rawValue == raw)
    }

    @Test(
        "Hostile or malformed card codes are rejected",
        arguments: [
            "", "0", "1234567", "01001A", "01001abc", "x", "xUPPER", "x" + String(
                repeating: "a",
                count: 17
            ),
            "../etc/passwd", "01001/../../secret", "01001%2e%2e", "01001 ", " 01001", "01001\n",
            "01001_mutated1", "01001_Mutated", "01001_Mutated1234", "01001_Mutated-1",
            String(repeating: "1", count: 41),
        ]
    )
    func hostileCardCodesRejected(raw: String) {
        #expect(throws: AssetError.invalidIdentifier(field: "cardCode")) {
            try AssetIdentifier.cardCode(raw)
        }
    }

    // MARK: - setOrBoxCode

    @Test(
        "Valid set/box codes are accepted",
        arguments: ["01", "03276a", "60101", "x05184"]
    )
    func validSetOrBoxCodesAccepted(raw: String) throws {
        let identifier = try AssetIdentifier.setOrBoxCode(raw)
        #expect(identifier.rawValue == raw)
    }

    @Test("A mutation suffix is not valid for a set/box code")
    func mutationSuffixRejectedForSetOrBoxCode() {
        #expect(throws: AssetError.invalidIdentifier(field: "setOrBoxCode")) {
            try AssetIdentifier.setOrBoxCode("04105_Mutated1")
        }
    }

    @Test(
        "Hostile set/box codes are rejected",
        arguments: ["", "../boxes/x", "01/02", "01 02"]
    )
    func hostileSetOrBoxCodesRejected(raw: String) {
        #expect(throws: AssetError.invalidIdentifier(field: "setOrBoxCode")) {
            try AssetIdentifier.setOrBoxCode(raw)
        }
    }

    // MARK: - homebrewSlug

    @Test(
        "Valid homebrew slugs are accepted",
        arguments: ["circus-ex-mortis", "dark-matter", "a", "a1-b2-c3"]
    )
    func validHomebrewSlugsAccepted(raw: String) throws {
        let identifier = try AssetIdentifier.homebrewSlug(raw)
        #expect(identifier.rawValue == raw)
    }

    @Test(
        "Hostile homebrew slugs are rejected",
        arguments: [
            "", "-leading-hyphen", "trailing-hyphen-", "double--hyphen-ok-actually-not",
            "Uppercase-Slug", "under_score", "../../etc/passwd", "slug/with/slash",
            "1-starts-with-digit", String(repeating: "a", count: 65),
        ]
    )
    func hostileHomebrewSlugsRejected(raw: String) {
        #expect(throws: AssetError.invalidIdentifier(field: "homebrewSlug")) {
            try AssetIdentifier.homebrewSlug(raw)
        }
    }

    @Test("A homebrew slug with an empty segment (double hyphen) is rejected")
    func emptySegmentRejected() {
        #expect(throws: AssetError.invalidIdentifier(field: "homebrewSlug")) {
            try AssetIdentifier.homebrewSlug("double--hyphen")
        }
    }

    // MARK: - homebrewTokenKey

    @Test(
        "Valid homebrew token keys are accepted",
        arguments: ["moon", "sun-and-moon", "token1"]
    )
    func validHomebrewTokenKeysAccepted(raw: String) throws {
        let identifier = try AssetIdentifier.homebrewTokenKey(raw)
        #expect(identifier.rawValue == raw)
    }

    @Test(
        "Hostile homebrew token keys are rejected",
        arguments: [
            "",
            "-leading",
            "trailing-",
            "Upper",
            "with space",
            "../secret",
            String(repeating: "a", count: 65),
        ]
    )
    func hostileHomebrewTokenKeysRejected(raw: String) {
        #expect(throws: AssetError.invalidIdentifier(field: "homebrewTokenKey")) {
            try AssetIdentifier.homebrewTokenKey(raw)
        }
    }

    // MARK: - backSlug

    @Test(
        "Valid back slugs are accepted",
        arguments: ["back_artifact", "children_of_blood", "a", "back-story-2"]
    )
    func validBackSlugsAccepted(raw: String) throws {
        let identifier = try AssetIdentifier.backSlug(raw)
        #expect(identifier.rawValue == raw)
    }

    @Test(
        "Hostile back slugs are rejected",
        arguments: [
            "",
            "1starts-with-digit",
            "Upper_Case",
            "../etc/passwd",
            "with space",
            String(repeating: "a", count: 65),
        ]
    )
    func hostileBackSlugsRejected(raw: String) {
        #expect(throws: AssetError.invalidIdentifier(field: "backSlug")) {
            try AssetIdentifier.backSlug(raw)
        }
    }

    // MARK: - Case sensitivity is preserved, never normalized

    @Test("Card code casing is preserved exactly, not lowercased")
    func cardCodeCasingPreserved() throws {
        // Uppercase letters are not part of the grammar at all (they are
        // rejected, not silently lowercased into a different, possibly
        // colliding path).
        #expect(throws: AssetError.invalidIdentifier(field: "cardCode")) {
            try AssetIdentifier.cardCode("01001B")
        }
    }

    // MARK: - artwork(from: CardCode) conversion

    @Test(
        "An official CardCode strips exactly one leading 'c' to produce a card-art AssetIdentifier"
    )
    func officialCardCodeConvertsToArtworkIdentifier() throws {
        let cardCode = try CardCode("c01001")
        let artwork = try AssetIdentifier.artwork(from: cardCode)
        guard case let .official(identifier) = artwork else {
            Issue.record("Expected .official, got \(artwork)")
            return
        }
        #expect(identifier.rawValue == "01001")
    }

    @Test(
        """
        A homebrew CardCode with a leading literal 'c' inside its campaign slug strips only \
        the Aeson prefix, never a second 'c'
        """
    )
    func homebrewCardCodeStripsExactlyOneLeadingC() throws {
        let cardCode = try CardCode("c:circus-ex-mortis:151")
        let artwork = try AssetIdentifier.artwork(from: cardCode)
        guard case let .homebrew(campaign, art) = artwork else {
            Issue.record("Expected .homebrew, got \(artwork)")
            return
        }
        #expect(campaign.rawValue == "circus-ex-mortis")
        #expect(art.rawValue == "151")
    }

    @Test(
        """
        A CardCode whose payload is only the Aeson prefix followed by an empty homebrew form \
        is rejected
        """
    )
    func emptyHomebrewSegmentsRejected() {
        // `CardCode.init` itself rejects a bare "c" (empty payload), so
        // the narrowest reachable empty-segment case is a homebrew form
        // with one side empty, e.g. "c::151" or "c:dark-matter:".
        for raw in ["c::151", "c:dark-matter:", "c:"] {
            let cardCode = try? CardCode(raw)
            guard let cardCode else {
                Issue.record(
                    "CardCode(\(raw)) should construct; only artwork(from:) should reject it"
                )
                continue
            }
            #expect(throws: AssetError.invalidIdentifier(field: "cardCode")) {
                _ = try AssetIdentifier.artwork(from: cardCode)
            }
        }
    }

    @Test("A homebrew CardCode with more than two ':'-delimited components is rejected")
    func homebrewTooManyComponentsRejected() throws {
        let cardCode = try CardCode("c:dark-matter:151:extra")
        #expect(throws: AssetError.invalidIdentifier(field: "cardCode")) {
            _ = try AssetIdentifier.artwork(from: cardCode)
        }
    }

    @Test("A homebrew CardCode whose campaign slug fails the homebrew-slug grammar is rejected")
    func homebrewInvalidSlugRejected() throws {
        let cardCode = try CardCode("c:Uppercase-Slug:151")
        #expect(throws: AssetError.invalidIdentifier(field: "homebrewSlug")) {
            _ = try AssetIdentifier.artwork(from: cardCode)
        }
    }

    @Test("A homebrew CardCode whose art code fails the card-code grammar is rejected")
    func homebrewInvalidArtCodeRejected() throws {
        let cardCode = try CardCode("c:dark-matter:151A")
        #expect(throws: AssetError.invalidIdentifier(field: "cardCode")) {
            _ = try AssetIdentifier.artwork(from: cardCode)
        }
    }
}
