@testable import ArkhamHorrorShared
import Testing

@Suite("DeckImportURL")
struct DeckImportURLTests {
    @Test(
        "Import URL recognition rewrites only supported HTTPS ArkhamDB and arkham.build links",
        arguments: [
            (
                "https://arkhamdb.com/decklist/view/4242",
                "https://arkhamdb.com/api/public/decklist/4242"
            ),
            (
                "https://arkhamdb.com/deck/4242",
                "https://arkhamdb.com/api/public/deck/4242"
            ),
            (
                "https://en.arkhamdb.com/decklist/4242",
                "https://arkhamdb.com/api/public/decklist/4242"
            ),
            (
                "https://arkhamdb.com/decklist/view/2381/roland-1.0",
                "https://arkhamdb.com/api/public/decklist/2381"
            ),
            (
                "https://arkham.build/decklist/view/abc123",
                "https://api.arkham.build/v1/public/share/abc123?type=decklist"
            ),
            (
                "HTTPS://User@Arkham.Build:8443/decklist/ABC_123?x=1#fragment",
                "https://api.arkham.build/v1/public/share/ABC_123?type=decklist"
            ),
            (
                "https://arkham.build/share/abc123",
                "https://api.arkham.build/v1/public/share/abc123"
            ),
            (
                "https://arkham.build/share/view/abc123",
                "https://api.arkham.build/v1/public/share/abc123"
            ),
            (
                "https://arkham.build/deck/view/abc123",
                "https://api.arkham.build/v1/public/share/abc123"
            ),
            (
                "https://api.arkham.build/v1/public/share/abc123?ignored=true",
                "https://api.arkham.build/v1/public/share/abc123"
            ),
            (
                "https://api.arkham.build/v1/public/share/abc123?type=decklist",
                "https://api.arkham.build/v1/public/share/abc123?type=decklist"
            ),
        ]
    )
    func importURLRecognition(rawURL: String, fetchURL: String) throws {
        #expect(try DeckImportURL.parse(rawURL).fetchURL == fetchURL)
    }

    @Test(
        "Import URL recognition rejects unsupported and SSRF-shaped inputs",
        arguments: [
            "http://arkhamdb.com/decklist/view/4242",
            "https://example.com/decklist/view/4242",
            "https://127.0.0.1/decklist/view/4242",
            "https://localhost/decklist/view/4242",
            "https://169.254.169.254/latest/meta-data",
            "https://arkhamdb.com.evil.test/decklist/view/4242",
            "https://arkhamdb.com/decklist/view/not-a-number",
            "https://arkhamdb.com/decklist/view/٣٣",
            "https://аrkham.build/decklist/abc123",
            "https://arkham.build/decklist/éabc",
            "https://arkham.build/decklist/../secret",
        ]
    )
    func importURLRecognitionRejects(rawURL: String) {
        #expect(throws: DeckImportURL.ParseError.self) {
            try DeckImportURL.parse(rawURL)
        }
    }
}
