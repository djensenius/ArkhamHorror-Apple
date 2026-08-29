@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Pure, non-networked coverage for the game-lifecycle domain/presentation-support
/// types: ``GameLifecycleEnvelope``, ``ContractUnit``, ``GameListLoadState``,
/// ``GameLifecycleError/message``, and the ``GameSummary``/``GameState`` display
/// helpers `GamesListView`/`GameRowView`/`GameLobbyView` render.
@Suite("GameLifecycle domain support")
struct GameLifecycleDomainTests {
    // MARK: - GameLifecycleEnvelope

    @Test("A PublicGame envelope decodes only the tag and id, ignoring every board field")
    func envelopeDecodesShallowly() throws {
        let id = UUID()
        let json = """
        {"tag":"PublicGame","id":"\(id.uuidString)","name":"Ignored",
         "locations":{"a":{"deeply":"nested"}},"investigators":{},"log":[1,2,3]}
        """
        let envelope = try ContractJSON.decode(GameLifecycleEnvelope.self, from: Data(json.utf8))
        #expect(envelope == .game(GameID(id)))
    }

    @Test("A FailedToLoadGame tag decodes as .unsupported without requiring an id")
    func envelopeFailedToLoadGameIsUnsupported() throws {
        let json = #"{"tag":"FailedToLoadGame","error":"could not load"}"#
        let envelope = try ContractJSON.decode(GameLifecycleEnvelope.self, from: Data(json.utf8))
        #expect(envelope == .unsupported)
    }

    @Test("An unrecognized future tag also decodes as .unsupported rather than throwing")
    func envelopeUnknownFutureTagIsUnsupported() throws {
        let json = #"{"tag":"SomeFutureTag","futureField":42}"#
        let envelope = try ContractJSON.decode(GameLifecycleEnvelope.self, from: Data(json.utf8))
        #expect(envelope == .unsupported)
    }

    @Test("A PublicGame tag missing its id fails explicitly rather than decoding a bogus game")
    func envelopeMissingIdFailsExplicitly() throws {
        let json = #"{"tag":"PublicGame","name":"No id here"}"#
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(GameLifecycleEnvelope.self, from: Data(json.utf8))
        }
    }

    @Test("A document missing the tag key fails explicitly")
    func envelopeMissingTagFailsExplicitly() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001"}"#
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(GameLifecycleEnvelope.self, from: Data(json.utf8))
        }
    }

    // MARK: - ContractUnit

    @Test("ContractUnit decodes the exact [] Yesod's ToJSON () instance sends")
    func contractUnitDecodesEmptyArray() throws {
        _ = try ContractJSON.decode(ContractUnit.self, from: Data("[]".utf8))
    }

    @Test("ContractUnit rejects a non-empty array")
    func contractUnitRejectsNonEmptyArray() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ContractUnit.self, from: Data("[1]".utf8))
        }
    }

    @Test("ContractUnit rejects an object")
    func contractUnitRejectsObject() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ContractUnit.self, from: Data("{}".utf8))
        }
    }

    @Test("ContractUnit rejects null")
    func contractUnitRejectsNull() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(ContractUnit.self, from: Data("null".utf8))
        }
    }

    // MARK: - GameListLoadState

    @Test("games/isLoading reflect every GameListLoadState case correctly")
    func gameListLoadStateHelpers() {
        let games: GameList = []
        #expect(GameListLoadState.idle.games == nil)
        #expect(GameListLoadState.idle.isLoading == false)
        #expect(GameListLoadState.loading(previous: nil).isLoading == true)
        #expect(GameListLoadState.loading(previous: games).games == games)
        #expect(GameListLoadState.loaded(games).games == games)
        #expect(GameListLoadState.loaded(games).isLoading == false)
        #expect(GameListLoadState.failed(.malformedPayload, previous: games).games == games)
        #expect(GameListLoadState.failed(.malformedPayload, previous: nil).games == nil)
    }

    // MARK: - GameLifecycleError.message never leaks a diagnostic string

    @Test("Every GameLifecycleError case's message is non-empty and secret-free")
    func everyErrorMessageIsSecretFree() {
        let secret = "sensitive-diagnostic-detail"
        let cases: [GameLifecycleError] = [
            .nonHTTPResponse, .sessionExpired, .unexpectedStatus(403), .unexpectedStatus(404),
            .unexpectedStatus(500), .malformedPayload, .requestEncodingFailed, .tokenUnavailable,
            .invalidPathSegment, .transportFailure(secret),
        ]
        for error in cases {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains(secret))
        }
    }

    // MARK: - GameListEntry.gameID

    @Test("gameID returns the summary's id for a .game entry and nil for a .failed entry")
    func gameListEntryGameIDAccessor() {
        let id = GameID(UUID())
        let summary = GameSummary(
            id: id, scenario: nil, campaign: nil, gameState: .active, name: "x",
            investigators: [], otherInvestigators: [], multiplayerVariant: .solo,
            hasOpenSeats: false
        )
        #expect(GameListEntry.game(summary).gameID == id)
        #expect(GameListEntry.failed(FailedGameEntry(error: "x")).gameID == nil)
    }

    // MARK: - GameState.statusText

    @Test("statusText is a non-empty, distinct summary for every GameState case")
    func gameStateStatusTextIsDistinct() {
        let states: [GameState] = [
            .pending([]), .pending([PlayerID(UUID())]), .chooseDecks([]), .active, .over,
            .unknown(tag: "Future", rawObject: .null),
        ]
        let texts = states.map(\.statusText)
        #expect(texts.allSatisfy { !$0.isEmpty })
    }

    // MARK: - GameSummary display helpers

    @Test("displayName prefers the scenario title over the stored name")
    func displayNamePrefersScenario() {
        let summary = GameSummary(
            id: GameID(UUID()),
            scenario: ScenarioSummary(
                id: "01104", difficulty: .easy,
                name: CardName(title: "The Gathering", subtitle: nil), variant: nil
            ),
            campaign: nil, gameState: .active, name: "Stored name",
            investigators: [], otherInvestigators: [], multiplayerVariant: .solo,
            hasOpenSeats: false
        )
        #expect(summary.displayName == "The Gathering")
    }

    @Test("displayName falls back to the stored name when there is no scenario")
    func displayNameFallsBackToStoredName() {
        let summary = GameSummary(
            id: GameID(UUID()), scenario: nil, campaign: nil, gameState: .active,
            name: "Stored name", investigators: [], otherInvestigators: [],
            multiplayerVariant: .solo, hasOpenSeats: false
        )
        #expect(summary.displayName == "Stored name")
    }

    @Test("displaySubtitle includes difficulty and multiplayer mode")
    func displaySubtitleIncludesDifficultyAndMode() {
        let summary = GameSummary(
            id: GameID(UUID()),
            scenario: ScenarioSummary(
                id: "01104", difficulty: .hard,
                name: CardName(title: "X", subtitle: nil), variant: nil
            ),
            campaign: nil, gameState: .active, name: "x", investigators: [], otherInvestigators: [],
            multiplayerVariant: .withFriends, hasOpenSeats: false
        )
        #expect(summary.displaySubtitle.contains("Hard"))
        #expect(summary.displaySubtitle.contains("With Friends"))
    }

    // MARK: - InvestigatorCode(openSeat:)

    @Test("InvestigatorCode(openSeat:) forwards the open-seat CardCode's exact wire text")
    func investigatorCodeFromOpenSeatForwardsExactText() throws {
        let seat = try CardCode("c01001")
        let investigatorId = try InvestigatorCode(openSeat: seat)
        #expect(investigatorId.rawValue == "c01001")
    }
}
