// swiftlint:disable file_length function_body_length
@testable import ArkhamHorrorShared
import CryptoKit
import Foundation
import Testing

private struct GovernedContractManifestFixture: Decodable {
    let path: String
    let schema: String
}

private struct GovernedContractMutationOperation: Decodable {
    let operation: String
    let pointer: String
    let value: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case operation = "op"
        case pointer
        case value
    }
}

private struct GovernedContractNegativeFixture: Decodable {
    let basePositiveFixture: String
    let basePointer: String
    let mutation: GovernedContractMutationOperation
}

private struct GovernedContractManifest: Decodable {
    let fixtures: [GovernedContractManifestFixture]
    let negativeFixtures: [GovernedContractNegativeFixture]
}

@Suite("ContractFixtureDigest")
// swiftlint:disable:next type_body_length
struct ContractFixtureDigestTests {
    /// The one subdirectory holding fixtures vendored from `ContractPin.current`'s pinned
    /// backend commit. `token.json`/`whoami.json` (synthetic auth fixtures, unrelated to
    /// the contract pin) live one level up in `Fixtures/`, deliberately outside this
    /// directory so they're never mistaken for a governed contract artifact.
    private static let contractFixturesSubdirectory = "Fixtures/Contract"

    private static func basenameWithoutExtension(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: Self.contractFixturesSubdirectory
            )
        )
        return try Data(contentsOf: url)
    }

    /// The file names actually bundled under `Fixtures/Contract`, derived from the real
    /// resource listing rather than a second hand-maintained literal. An addition,
    /// removal, or basename substitution in that directory changes this set without any
    /// source edit elsewhere, so comparing it against ``ContractFixtureDigests/all`` below
    /// actually catches drift instead of comparing two copies of the same hardcoded list.
    private func actualBundledFileNames() throws -> Set<String> {
        let urls = try #require(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: Self.contractFixturesSubdirectory
            ),
            "Expected at least one bundled fixture under \(Self.contractFixturesSubdirectory)"
        )
        return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
    }

    @Test("Every registered digest matches the bundled fixture's actual SHA-256")
    func everyDigestMatchesBundledBytes() throws {
        for entry in ContractFixtureDigests.all {
            let data = try fixtureData(named: entry.fileName)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            #expect(
                hex == entry.sha256Hex,
                "Fixture '\(entry.fileName).json' has drifted from its pinned SHA-256 digest"
            )
        }
    }

    @Test(
        """
        The digest registry's file-name set exactly matches what's actually bundled under \
        Fixtures/Contract
        """
    )
    func registryExactlyMatchesBundledDirectory() throws {
        let registered = Set(ContractFixtureDigests.all.map(\.fileName))
        let actual = try actualBundledFileNames()
        #expect(
            registered == actual,
            """
            Registry/directory mismatch: registered-only=\(registered.subtracting(actual)), \
            bundled-only=\(actual.subtracting(registered))
            """
        )
    }

    @Test("The digest registry has no duplicate basename")
    func registryHasNoDuplicateBasename() {
        let names = ContractFixtureDigests.all.map(\.fileName)
        #expect(names.count == Set(names).count, "Duplicate basename found in \(names)")
    }

    @Test("The digest table covers the explicitly vendored contract scope")
    func tableCoversExpectedFiles() {
        let expected = Set([
            "act-no-advance-cost",
            "answer-enemy-attack",
            "answer-enemy-attack-assign-damage",
            "answer-enemy-attack-assign-horror",
            "answer-enemy-attack-assign-remaining-damage",
            "answer-enemy-attack-assign-remaining-horror",
            "answer-question",
            "basic-choice-question.schema",
            "capabilities",
            "capabilities-locale-catalog",
            "capabilities.schema",
            "card-code-entity-map",
            "catalog",
            "client-answer.schema",
            "decks",
            "game-lifecycle",
            "game-list",
            "game-update",
            "get-game",
            "investigator-unhealed-horror-negative",
            "location-enemy-view",
            "manifest",
            "mode-campaign-only",
            "mode-campaign-scenario",
            "mode-turn-zero",
            "movement",
            "question-agenda-advance",
            "question-agenda-consequence",
            "question-agenda-horror-assignment",
            "question-choose-one",
            "question-choose-one-location",
            "question-choose-one-location-multiple",
            "question-cover-up-reaction",
            "question-encounter-deck-draw",
            "question-enemy-attack",
            "question-enemy-attack-damage-assignment",
            "question-enemy-attack-remaining-damage-assignment",
            "question-enemy-attack-remaining-horror-assignment",
            "question-gathering-act-advance",
            "question-gathering-act-objective",
            "question-gathering-attic-entry-forced",
            "question-gathering-attic-horror-assignment",
            "question-gathering-cellar-damage-assignment",
            "question-gathering-cellar-entry-forced",
            "question-gathering-movement",
            "question-generic-choose-amounts",
            "question-generic-choose-deck",
            "question-generic-choose-n",
            "question-generic-choose-some",
            "question-generic-choose-up-to-n",
            "question-generic-cost-ability-window",
            "question-generic-invalid-info",
            "question-generic-one-at-a-time-auto",
            "question-generic-one-from-each",
            "question-generic-payment-amounts",
            "question-generic-read",
            "question-generic-skill-label",
            "question-generic-wrapped",
            "question-investigate-apply-results",
            "question-investigate-commit",
            "question-investigate-fast-window",
            "question-investigate-reveal-window",
            "question-mulligan",
            "question-player-window-choose-one",
            "question-player-window-enemy-actions",
            "question-player-window-engage-action",
            "question-presentation-encounter-deck-draw",
            "question-presentation-gathering-act-advance",
            "question-presentation-gathering-act-objective",
            "question-presentation-gathering-attic-entry-forced",
            "question-presentation-gathering-attic-horror-assignment",
            "question-presentation-gathering-cellar-damage-assignment",
            "question-presentation-gathering-cellar-entry-forced",
            "question-presentation-gathering-movement",
            "question-presentation-generic-choose-amounts",
            "question-presentation-generic-choose-deck",
            "question-presentation-generic-choose-n",
            "question-presentation-generic-choose-some",
            "question-presentation-generic-choose-up-to-n",
            "question-presentation-generic-cost-ability-window",
            "question-presentation-generic-invalid-info",
            "question-presentation-generic-one-at-a-time-auto",
            "question-presentation-generic-one-from-each",
            "question-presentation-generic-payment-amounts",
            "question-presentation-generic-read",
            "question-presentation-generic-skill-label",
            "question-presentation-generic-wrapped",
            "question-presentation-representatives",
            "question-presentation-representatives.schema",
            "question-presentation-treachery-forced-ability",
            "question-presentation.schema",
            "question-read",
            "question-read-scenario-intro",
            "question-read-with-cards",
            "question-roland-defeat-reaction",
            "question-round-end-forced-ability",
            "question-treachery-forced-ability",
            "question-window-choose-one",
            "raw-question-fixture.schema",
            "replay-attestation",
            "replay-attestation.schema",
            "uuid-entity-map",
        ])
        #expect(Set(ContractFixtureDigests.all.map(\.fileName)) == expected)
    }

    @Test("Synthetic auth fixtures are bundled outside the governed Contract subdirectory")
    func authFixturesStayOutsideContractDirectory() throws {
        let contractNames = try actualBundledFileNames()
        #expect(!contractNames.contains("token"))
        #expect(!contractNames.contains("whoami"))
        // Confirm they still exist, just one directory up, so this isn't vacuously true
        // because the fixtures were deleted rather than deliberately relocated.
        for name in ["token", "whoami"] {
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
            #expect(
                url != nil,
                "Expected '\(name).json' to still be bundled under plain Fixtures/"
            )
        }
    }

    @Test("The vendored manifest's schemaRevision matches ContractPin.current exactly")
    func manifestSchemaRevisionMatchesPin() throws {
        struct ManifestFixture: Decodable {
            let schemaRevision: ContractRevision
        }
        let data = try fixtureData(named: "manifest")
        let manifest = try JSONDecoder().decode(ManifestFixture.self, from: data)
        #expect(manifest.schemaRevision == ContractPin.current.supportedSchemaRevision)
    }

    @Test(
        """
        Every non-manifest registered fixture's basename matches a path the manifest itself \
        documents
        """
    )
    func registeredFixturesMatchManifestPaths() throws {
        struct ManifestFixtureEntry: Decodable {
            let path: String
            let schema: String
        }
        struct ManifestFixture: Decodable {
            let fixtures: [ManifestFixtureEntry]
        }
        let manifestData = try fixtureData(named: "manifest")
        let manifest = try JSONDecoder().decode(ManifestFixture.self, from: manifestData)
        let manifestBasenames = Set(
            manifest.fixtures.flatMap {
                [($0.path as NSString).lastPathComponent, ($0.schema as NSString).lastPathComponent]
            }
        )
        for entry in ContractFixtureDigests.all where entry.fileName != "manifest" {
            #expect(
                manifestBasenames.contains("\(entry.fileName).json"),
                """
                Registered fixture '\(entry.fileName).json' has no matching path in the \
                manifest's own fixtures list
                """
            )
        }
    }

    @Test("ContractPin.current is pinned to the documented backend commit")
    func pinnedToDocumentedCommit() {
        #expect(
            ContractPin.current.backendCommit == "f3a0acbe2c6952c5fbb3f3374a3ef85f94f250e1"
        )
    }

    @Test("The immutable manifest governs 32 assignment negatives within 629 total")
    func assignmentFamilyManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        #expect(manifest.negativeFixtures.count == 629)
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        var assignmentNegativeCount = 0

        for fixture in AssignmentContinuationFixture.allCases {
            let questionPath = "contracts/fixtures/\(fixture.questionFixture).json"
            let answerPath = "contracts/fixtures/\(fixture.answerFixture).json"
            #expect(fixtureSchemas[questionPath]
                == "contracts/schemas/basic-choice-question.schema.json")
            #expect(fixtureSchemas[answerPath]
                == "contracts/schemas/client-answer.schema.json")

            let negatives = manifest.negativeFixtures.filter {
                $0.basePositiveFixture == questionPath
            }
            #expect(negatives.count == 16)
            #expect(negatives.count {
                $0.basePointer == "/question/question/choices/0/messages/1"
                    && $0.mutation.operation == "replace"
                    && $0.mutation.pointer == "/contents/contents/3/tag"
                    && $0.mutation.value == .string("AssetWithTitle")
            } == 1)
            assignmentNegativeCount += negatives.count
        }

        #expect(assignmentNegativeCount == 32)
    }

    @Test("The immutable manifest governs the Gathering act raw and presentation fixtures")
    func gatheringActPresentationManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        let basicChoiceSchema = "contracts/schemas/basic-choice-question.schema.json"
        let presentationSchema = "contracts/schemas/question-presentation.schema.json"
        let objectiveQuestion = "contracts/fixtures/question-gathering-act-objective.json"
        let advanceQuestion = "contracts/fixtures/question-gathering-act-advance.json"
        let objectivePresentation =
            "contracts/fixtures/question-presentation-gathering-act-objective.json"
        let advancePresentation =
            "contracts/fixtures/question-presentation-gathering-act-advance.json"

        #expect(fixtureSchemas[objectiveQuestion] == basicChoiceSchema)
        #expect(fixtureSchemas[advanceQuestion] == basicChoiceSchema)
        #expect(fixtureSchemas[objectivePresentation] == presentationSchema)
        #expect(fixtureSchemas[advancePresentation] == presentationSchema)
        #expect(
            manifest.negativeFixtures.count {
                $0.basePositiveFixture == objectivePresentation
            } == 6
        )
        #expect(
            manifest.negativeFixtures.count {
                $0.basePositiveFixture == advancePresentation
            } == 1
        )
    }

    @Test("The immutable manifest governs the production enemy-action menu")
    func enemyActionManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let path = "contracts/fixtures/question-player-window-enemy-actions.json"
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        #expect(fixtureSchemas[path] == "contracts/schemas/basic-choice-question.schema.json")
        #expect(manifest.negativeFixtures.count { $0.basePositiveFixture == path } == 2)
    }

    @Test("The immutable manifest governs the production post-Evade Engage menu")
    func engageActionManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let path = "contracts/fixtures/question-player-window-engage-action.json"
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        #expect(fixtureSchemas[path] == "contracts/schemas/basic-choice-question.schema.json")
        #expect(manifest.negativeFixtures.count { $0.basePositiveFixture == path } == 3)
    }

    @Test("The immutable manifest governs the production Roland reaction")
    func rolandReactionManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let path = "contracts/fixtures/question-roland-defeat-reaction.json"
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        #expect(fixtureSchemas[path] == "contracts/schemas/basic-choice-question.schema.json")
        #expect(manifest.negativeFixtures.count { $0.basePositiveFixture == path } == 60)
    }

    @Test("The immutable manifest governs the production Cover Up reaction")
    func coverUpReactionManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let path = "contracts/fixtures/question-cover-up-reaction.json"
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        #expect(fixtureSchemas[path] == "contracts/schemas/basic-choice-question.schema.json")
        #expect(manifest.negativeFixtures.count { $0.basePositiveFixture == path } == 88)
    }

    @Test("The immutable manifest governs all four round-transition prompts")
    func roundTransitionManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        let expectedCounts = [
            "contracts/fixtures/question-round-end-forced-ability.json": 12,
            "contracts/fixtures/question-agenda-advance.json": 7,
            "contracts/fixtures/question-agenda-consequence.json": 15,
            "contracts/fixtures/question-agenda-horror-assignment.json": 21,
        ]
        let fixtureSchemas = Dictionary(
            uniqueKeysWithValues: manifest.fixtures.map { ($0.path, $0.schema) }
        )
        for (path, expectedCount) in expectedCounts {
            #expect(fixtureSchemas[path]
                == "contracts/schemas/basic-choice-question.schema.json")
            #expect(
                manifest.negativeFixtures.count { $0.basePositiveFixture == path }
                    == expectedCount
            )
        }
        #expect(expectedCounts.values.reduce(0, +) == 55)
    }

    @Test("Registered fixture and schema digests match the backend manifest's artifact hashes")
    func registeredDigestsMatchManifestHashes() throws {
        struct Manifest: Decodable {
            let artifactHashes: [String: String]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixtureData(named: "manifest"))
        for entry in ContractFixtureDigests.all where entry.fileName != "manifest" {
            let directory = entry.fileName.hasSuffix(".schema") ? "schemas" : "fixtures"
            let path = "contracts/\(directory)/\(entry.fileName).json"
            #expect(manifest.artifactHashes[path] == entry.sha256Hex, "Digest drift at \(path)")
        }
    }
}
