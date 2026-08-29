@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Verifies that the compact, shipped digest resources under
/// `Sources/ArkhamHorrorShared/Resources/AssetDigests/` are exactly what
/// ``LocalizedDigestCompactor/compactCardIdentifiers(fromRawEntries:)``
/// produces from the pinned, vendored raw upstream digests. A failure here
/// means the shipped resources have drifted from their generator (or from
/// the pinned upstream commit) and must be regenerated, not hand-edited.
@Suite("LocalizedDigestCompactor drift")
struct LocalizedDigestCompactorDriftTests {
    private static let locales: [AssetLocale] = [.italian, .french, .spanish, .korean, .chinese]

    @Test(
        "Every shipped digest resource matches the compactor's output for the pinned fixture",
        arguments: locales
    )
    func shippedResourceMatchesCompactorOutput(locale: AssetLocale) throws {
        let resourceName = try #require(locale.digestResourceName)
        let rawURL = try #require(
            Bundle.module.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "Fixtures/LocaleDigests/raw"
            )
        )
        let rawEntries = try JSONDecoder().decode([String].self, from: Data(contentsOf: rawURL))
        // The compactor's own contract already sorts and deduplicates its
        // output (see `LocalizedDigest.compactCardIdentifiers`), so
        // comparing the shipped resource against it as an ordered array
        // (not a `Set`) also catches ordering drift or accidental
        // duplicate entries the shipped JSON could otherwise carry
        // undetected — a `Set`-to-`Set` comparison alone could not.
        let compacted = LocalizedDigestCompactor.compactCardIdentifiers(fromRawEntries: rawEntries)

        let shipped = try #require(
            try BundledLocalizedDigestProvider().orderedIdentifiers(for: locale)
        )
        #expect(shipped == compacted)
    }

    @Test("The compactor is idempotent: recompacting its own output changes nothing")
    func compactorIsIdempotent() throws {
        let resourceName = try #require(AssetLocale.italian.digestResourceName)
        let rawURL = try #require(
            Bundle.module.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "Fixtures/LocaleDigests/raw"
            )
        )
        let rawEntries = try JSONDecoder().decode([String].self, from: Data(contentsOf: rawURL))
        let once = LocalizedDigestCompactor.compactCardIdentifiers(fromRawEntries: rawEntries)
        let asPaths = once.map { "cards/\($0).avif" }
        let twice = LocalizedDigestCompactor.compactCardIdentifiers(fromRawEntries: asPaths)
        #expect(once == twice)
    }

    @Test(
        "An entry with a bad prefix, extension, or malformed code is dropped, not compacted"
    )
    func malformedEntriesAreDropped() {
        let result = LocalizedDigestCompactor.compactCardIdentifiers(fromRawEntries: [
            "cards/01001.avif",
            "portraits/01001.jpg", // wrong prefix
            "cards/01002.bmp", // unrecognized extension
            "cards/01001B.avif", // uppercase suffix: fails cardCode grammar
            "cards/51025-.avif", // trailing hyphen: fails cardCode grammar
            "cards/noextension",
        ])
        #expect(result == ["01001"])
    }
}
