@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

/// An internal fixture gallery/harness: decodes the exact governed `get-game`/
/// `game-update` fixture bytes through production `ContractJSON`, builds each through
/// production ``BoardProjectionBuilder``, and renders both through the exact same
/// reusable ``BoardView`` a future root-integration PR will use — entirely without a
/// server. This lives in the test target (never the app target) since this issue adds no
/// root navigation destination; `@testable import` already gives every test, and this
/// harness, full access to ``BoardView``'s non-`public` API.
enum BoardGalleryHarness {
    private static func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    /// The REST `get-game` fixture's projection.
    static func restProjection() throws -> BoardProjection {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        return BoardProjectionBuilder.makeProjection(from: envelope.game)
    }

    /// The WebSocket `game-update` fixture's projection.
    static func webSocketProjection() throws -> BoardProjection {
        let update = try ContractJSON.decode(
            BoardSnapshotUpdate.self, from: fixtureData(named: "game-update")
        )
        guard case let .snapshot(snapshot) = update else {
            struct UnexpectedGameUpdateShape: Error {}
            throw UnexpectedGameUpdateShape()
        }
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }
}

/// A manual-preview/developer gallery listing both governed fixtures' rendered boards
/// side by side, each in its own independent ``BoardView`` instance (proving multiple
/// simultaneous board instances never share mutable focus/zoom state).
struct BoardGalleryView: View {
    let restProjection: BoardProjection
    let webSocketProjection: BoardProjection

    var body: some View {
        TabView {
            BoardView(projection: restProjection)
                .tabItem { Text("REST fixture") }
            BoardView(projection: webSocketProjection)
                .tabItem { Text("WebSocket fixture") }
        }
    }
}

#if DEBUG
    #Preview("Board gallery — governed fixtures") {
        BoardGalleryPreviewContent()
    }

    /// Extracted purely so the `try?`-guarded fixture load reads as a plain `if let`
    /// (avoiding a multi-condition brace SwiftLint's `opening_brace` rule flags) rather
    /// than living inline inside the `#Preview` macro's own trailing closure.
    private struct BoardGalleryPreviewContent: View {
        var body: some View {
            if let projections = try? loadedProjections() {
                BoardGalleryView(
                    restProjection: projections.rest, webSocketProjection: projections.webSocket
                )
            } else {
                Text("Failed to load governed fixtures")
            }
        }

        private func loadedProjections() throws -> (
            rest: BoardProjection, webSocket: BoardProjection
        ) {
            try (
                BoardGalleryHarness.restProjection(),
                BoardGalleryHarness.webSocketProjection()
            )
        }
    }
#endif

/// Proves the gallery harness itself actually decodes both governed fixtures and can
/// construct the reusable ``BoardView`` (and ``BoardCommandController``) from each,
/// without a server — the harness's own smoke test, separate from
/// ``BoardProjectionFixtureTests``'s deeper field-level assertions.
@MainActor
@Suite("BoardGalleryHarness — fixture-backed board construction")
struct BoardGalleryHarnessTests {
    @Test("Both governed fixtures decode into a BoardView-ready projection")
    func bothFixturesProduceARenderableProjection() throws {
        let rest = try BoardGalleryHarness.restProjection()
        let webSocket = try BoardGalleryHarness.webSocketProjection()
        #expect(rest == webSocket)
        _ = BoardView(projection: rest)
        _ = BoardView(projection: webSocket)
    }

    @Test("Two independent BoardCommandController instances never share focus/zoom state")
    func independentControllersDoNotShareMutableState() throws {
        let rest = try BoardGalleryHarness.restProjection()
        let first = BoardCommandController(projection: rest)
        let second = BoardCommandController(projection: rest)
        first.handle(.command(.zoomIn))
        first.handle(.command(.cycleZone(.next)))
        #expect(first.zoomScale != second.zoomScale)
        #expect(first.coordinator.currentFocus != second.coordinator.currentFocus)
    }
}
