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

    @Test("The digest table covers every governed contract fixture")
    func tableCoversExpectedFiles() {
        let fileNames = Set(ContractFixtureDigests.all.map(\.fileName))
        #expect(fileNames == [
            "manifest", "capabilities", "catalog", "decks", "game-lifecycle", "game-list",
            "get-game", "game-update", "mode-turn-zero", "mode-campaign-only",
            "mode-campaign-scenario", "location-enemy-view", "movement",
            "act-no-advance-cost", "investigator-unhealed-horror-negative",
            "uuid-entity-map", "card-code-entity-map", "question-choose-one",
            "question-player-window-choose-one", "question-window-choose-one",
            "question-gathering-act-objective", "question-gathering-act-advance",
            "question-presentation-gathering-act-objective",
            "question-presentation-gathering-act-advance",
            "answer-question", "question-read", "question-read-scenario-intro",
            "question-read-with-cards",
            "question-choose-one-location", "question-choose-one-location-multiple",
            "question-mulligan",
            "question-investigate-fast-window", "question-investigate-commit",
            "question-investigate-reveal-window", "question-investigate-apply-results",
            "question-encounter-deck-draw", "question-enemy-attack", "answer-enemy-attack",
            "question-enemy-attack-damage-assignment",
            "answer-enemy-attack-assign-damage", "answer-enemy-attack-assign-horror",
            "question-enemy-attack-remaining-damage-assignment",
            "question-enemy-attack-remaining-horror-assignment",
            "answer-enemy-attack-assign-remaining-damage",
            "answer-enemy-attack-assign-remaining-horror",
            "question-player-window-enemy-actions",
            "question-player-window-engage-action",
            "question-roland-defeat-reaction",
            "question-cover-up-reaction",
            "question-round-end-forced-ability",
            "question-agenda-advance",
            "question-agenda-consequence",
            "question-agenda-horror-assignment",
            "replay-attestation",
            "replay-attestation.schema",
            "basic-choice-question.schema",
            "question-presentation.schema",
        ])
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
            ContractPin.current.backendCommit == "503e3e4c8cdf8370cba78ac0397e3a2e5c7eee8a"
        )
    }

    @Test("The immutable manifest governs 32 assignment negatives within 582 total")
    func assignmentFamilyManifestCoverage() throws {
        let manifest = try ContractJSON.decode(
            GovernedContractManifest.self,
            from: fixtureData(named: "manifest")
        )
        #expect(manifest.negativeFixtures.count == 582)
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
