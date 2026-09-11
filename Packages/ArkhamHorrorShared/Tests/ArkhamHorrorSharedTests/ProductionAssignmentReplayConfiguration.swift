@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

enum ProductionAssignmentReplayCheckpoint: String, CaseIterable, ProductionReplayCheckpoint {
    case damageFirstThenRemainingHorror = "damage-first-then-remaining-horror"
    case horrorFirstThenRemainingDamage = "horror-first-then-remaining-damage"

    var sourceIndex: Int {
        switch self {
        case .damageFirstThenRemainingHorror: 0
        case .horrorFirstThenRemainingDamage: 1
        }
    }

    var selectedAssignmentKind: EnemyAttackAssignmentKind {
        switch self {
        case .damageFirstThenRemainingHorror: .damage
        case .horrorFirstThenRemainingDamage: .horror
        }
    }

    var nextAssignmentKind: EnemyAttackAssignmentKind {
        switch self {
        case .damageFirstThenRemainingHorror: .horror
        case .horrorFirstThenRemainingDamage: .damage
        }
    }

    var assignmentBefore: AssignmentReplayFields {
        AssignmentReplayFields(
            assignedHealthDamage: 0,
            assignedSanityDamage: 0
        )
    }

    var assignmentAfter: AssignmentReplayFields {
        switch self {
        case .damageFirstThenRemainingHorror:
            AssignmentReplayFields(
                assignedHealthDamage: 1,
                assignedSanityDamage: 0
            )
        case .horrorFirstThenRemainingDamage:
            AssignmentReplayFields(
                assignedHealthDamage: 0,
                assignedSanityDamage: 1
            )
        }
    }

    var assignmentDelta: AssignmentReplayFields {
        assignmentAfter.subtracting(assignmentBefore)
    }
}

extension EnemyAttackAssignmentKind {
    var productionReplayName: String {
        switch self {
        case .damage: "damage"
        case .horror: "horror"
        }
    }
}

struct AssignmentReplayFields: Codable, Equatable, Sendable {
    let assignedHealthDamage: Int
    let assignedSanityDamage: Int

    func subtracting(
        _ other: AssignmentReplayFields
    ) -> AssignmentReplayFields {
        AssignmentReplayFields(
            assignedHealthDamage: assignedHealthDamage - other.assignedHealthDamage,
            assignedSanityDamage: assignedSanityDamage - other.assignedSanityDamage
        )
    }
}

struct ProductionAssignmentReplayPromptIdentity: Equatable, Sendable {
    let gameID: GameID
    let ownerID: PlayerID
    let enemyID: EnemyID
    let investigatorID: InvestigatorID
}

enum ProductionAssignmentReplayEnvironmentKey {
    static let prefix = "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_"
    static let checkpoint = prefix + "CASE"
    static let resultPath = prefix + "RESULT_PATH"
    static let deadlineSeconds = prefix + "DEADLINE_SECONDS"
    static let serverBaseURL = prefix + "SERVER_BASE_URL"
    static let serverProfileID = prefix + "SERVER_PROFILE_ID"
    static let authToken = prefix + "AUTH_TOKEN"
    static let gameID = prefix + "GAME_ID"
    static let playerID = prefix + "PLAYER_ID"
    static let expectedBackendRevision = prefix + "EXPECTED_BACKEND_REVISION"
    static let expectedAppleRevision = prefix + "EXPECTED_APPLE_REVISION"
    static let expectedContractRevision = prefix + "EXPECTED_CONTRACT_REVISION"
    static let expectedCatalogRevision = prefix + "EXPECTED_CATALOG_REVISION"
    static let expectedPromptEnemyID = prefix + "EXPECTED_STARTING_PROMPT_ENEMY_ID"
    static let expectedPromptInvestigatorID =
        prefix + "EXPECTED_STARTING_PROMPT_INVESTIGATOR_ID"
    static let expectedPromptDigest = prefix + "EXPECTED_STARTING_PROMPT_DIGEST"
    static let expectedPromptVersion = prefix + "EXPECTED_STARTING_PROMPT_VERSION"
    static let observedAppleRevision = prefix + "OBSERVED_APPLE_REVISION"

    static let known = Set([
        checkpoint,
        resultPath,
        deadlineSeconds,
        serverBaseURL,
        serverProfileID,
        authToken,
        gameID,
        playerID,
        expectedBackendRevision,
        expectedAppleRevision,
        expectedContractRevision,
        expectedCatalogRevision,
        expectedPromptEnemyID,
        expectedPromptInvestigatorID,
        expectedPromptDigest,
        expectedPromptVersion,
        observedAppleRevision,
    ])
}

enum AssignmentReplayConfigurationError: Error, Equatable {
    case unknownEnvironmentKey(String)
    case missingEnvironmentKey(String)
    case forbiddenEnvironmentKey(String)
    case invalidEnvironmentValue(String)
    case checkpointMismatch
    case backendRevisionMismatch
    case appleRevisionMismatch
    case contractRevisionMismatch
}

// swiftlint:disable:next type_body_length
struct ProductionAssignmentReplayConfiguration: Sendable {
    static let maximumDeadlineSeconds = 300

    let checkpoint: ProductionAssignmentReplayCheckpoint
    let deadlineSeconds: Double
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionAssignmentReplayPromptIdentity
    let expectedBackendRevision: String
    let expectedAppleRevision: String
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let expectedPromptDigest: String
    let expectedPromptVersion: Int

    init(
        checkpoint: ProductionAssignmentReplayCheckpoint,
        deadlineSeconds: Double,
        serverProfile: ServerProfile,
        authToken: String,
        promptIdentity: ProductionAssignmentReplayPromptIdentity,
        expectedBackendRevision: String,
        expectedAppleRevision: String,
        expectedContractRevision: ContractRevision,
        expectedCatalogRevision: String,
        expectedPromptDigest: String,
        expectedPromptVersion: Int
    ) throws {
        try Self.validateRuntimeValues(
            deadlineSeconds: deadlineSeconds,
            authToken: authToken,
            promptDigest: expectedPromptDigest,
            promptVersion: expectedPromptVersion
        )
        try Self.validateExpectedRevisions(
            backend: expectedBackendRevision,
            apple: expectedAppleRevision,
            contract: expectedContractRevision,
            catalog: expectedCatalogRevision
        )
        self.checkpoint = checkpoint
        self.deadlineSeconds = deadlineSeconds
        self.serverProfile = serverProfile
        self.authToken = authToken
        self.promptIdentity = promptIdentity
        self.expectedBackendRevision = expectedBackendRevision
        self.expectedAppleRevision = expectedAppleRevision
        self.expectedContractRevision = expectedContractRevision
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedPromptDigest = expectedPromptDigest
        self.expectedPromptVersion = expectedPromptVersion
    }

    private static func validateRuntimeValues(
        deadlineSeconds: Double,
        authToken: String,
        promptDigest: String,
        promptVersion: Int
    ) throws {
        guard deadlineSeconds.isFinite,
              deadlineSeconds.rounded(.towardZero) == deadlineSeconds,
              (1 ... Double(maximumDeadlineSeconds)).contains(deadlineSeconds)
        else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.deadlineSeconds
            )
        }
        guard (1 ... 4096).contains(authToken.utf8.count),
              authToken.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) })
        else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.authToken
            )
        }
        guard LocaleCatalogGrammar.isSHA256Hex(promptDigest) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest
            )
        }
        guard promptVersion >= 0, promptVersion < Int.max else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion
            )
        }
    }

    private static func validateExpectedRevisions(
        backend: String,
        apple: String,
        contract: ContractRevision,
        catalog: String
    ) throws {
        guard isLowercaseHex(backend, count: 40) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedBackendRevision
            )
        }
        guard isLowercaseHex(apple, count: 40) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedAppleRevision
            )
        }
        guard LocaleCatalogGrammar.isCatalogRevision(catalog) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedCatalogRevision
            )
        }
        guard backend == ContractPin.current.backendCommit else {
            throw AssignmentReplayConfigurationError.backendRevisionMismatch
        }
        guard contract == ContractPin.current.supportedSchemaRevision else {
            throw AssignmentReplayConfigurationError.contractRevisionMismatch
        }
    }

    static func child(
        environment: [String: String],
        checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws -> ProductionAssignmentReplayConfiguration {
        try validateKnownKeys(environment)
        let values = try parseExternalValues(environment)
        guard values.configuration.checkpoint == checkpoint else {
            throw AssignmentReplayConfigurationError.checkpointMismatch
        }
        let observed = try required(
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision,
            in: environment
        )
        guard isLowercaseHex(observed, count: 40) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
            )
        }
        guard observed == values.configuration.expectedAppleRevision else {
            throw AssignmentReplayConfigurationError.appleRevisionMismatch
        }
        return values.configuration
    }

    func childEnvironment(observedAppleRevision: String) throws -> [String: String] {
        guard observedAppleRevision == expectedAppleRevision else {
            throw AssignmentReplayConfigurationError.appleRevisionMismatch
        }
        return [
            ProductionAssignmentReplayEnvironmentKey.checkpoint: checkpoint.rawValue,
            ProductionAssignmentReplayEnvironmentKey.deadlineSeconds:
                String(Int(deadlineSeconds)),
            ProductionAssignmentReplayEnvironmentKey.serverBaseURL:
                serverProfile.endpointSummary,
            ProductionAssignmentReplayEnvironmentKey.serverProfileID:
                serverProfile.id.uuidString.lowercased(),
            ProductionAssignmentReplayEnvironmentKey.authToken: authToken,
            ProductionAssignmentReplayEnvironmentKey.gameID:
                promptIdentity.gameID.codingKey.stringValue,
            ProductionAssignmentReplayEnvironmentKey.playerID:
                promptIdentity.ownerID.codingKey.stringValue,
            ProductionAssignmentReplayEnvironmentKey.expectedBackendRevision:
                expectedBackendRevision,
            ProductionAssignmentReplayEnvironmentKey.expectedAppleRevision:
                expectedAppleRevision,
            ProductionAssignmentReplayEnvironmentKey.expectedContractRevision:
                expectedContractRevision.description,
            ProductionAssignmentReplayEnvironmentKey.expectedCatalogRevision:
                expectedCatalogRevision,
            ProductionAssignmentReplayEnvironmentKey.expectedPromptEnemyID:
                promptIdentity.enemyID.codingKey.stringValue,
            ProductionAssignmentReplayEnvironmentKey.expectedPromptInvestigatorID:
                promptIdentity.investigatorID.codingKey.stringValue,
            ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest:
                expectedPromptDigest,
            ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion:
                String(expectedPromptVersion),
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision:
                observedAppleRevision,
        ]
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    fileprivate static func parseExternalValues(
        _ environment: [String: String]
    ) throws -> (
        configuration: ProductionAssignmentReplayConfiguration,
        resultURL: URL
    ) {
        let checkpointRaw = try required(
            ProductionAssignmentReplayEnvironmentKey.checkpoint,
            in: environment
        )
        guard let checkpoint = ProductionAssignmentReplayCheckpoint(rawValue: checkpointRaw) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.checkpoint
            )
        }
        let resultPath = try required(
            ProductionAssignmentReplayEnvironmentKey.resultPath,
            in: environment
        )
        guard resultPath.hasPrefix("/") else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.resultPath
            )
        }
        let deadline = try canonicalInteger(
            ProductionAssignmentReplayEnvironmentKey.deadlineSeconds,
            in: environment,
            allowed: 1 ... maximumDeadlineSeconds
        )
        let profileIDRaw = try required(
            ProductionAssignmentReplayEnvironmentKey.serverProfileID,
            in: environment
        )
        guard let profileID = UUID(uuidString: profileIDRaw),
              profileID.uuidString.lowercased() == profileIDRaw
        else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.serverProfileID
            )
        }
        let baseURL = try required(
            ProductionAssignmentReplayEnvironmentKey.serverBaseURL,
            in: environment
        )
        let profile: ServerProfile
        do {
            profile = try ServerProfile.custom(
                id: profileID,
                displayName: "Production assignment replay",
                rawURL: baseURL
            )
        } catch {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.serverBaseURL
            )
        }
        guard profile.endpointSummary == baseURL else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.serverBaseURL
            )
        }
        let token = try required(
            ProductionAssignmentReplayEnvironmentKey.authToken,
            in: environment
        )
        guard (1 ... 4096).contains(token.utf8.count),
              token.utf8.allSatisfy({ (0x21 ... 0x7E).contains($0) })
        else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.authToken
            )
        }
        let gameID = try identifier(
            GameID.self,
            key: ProductionAssignmentReplayEnvironmentKey.gameID,
            environment: environment
        )
        let playerID = try identifier(
            PlayerID.self,
            key: ProductionAssignmentReplayEnvironmentKey.playerID,
            environment: environment
        )
        let enemyID = try identifier(
            EnemyID.self,
            key: ProductionAssignmentReplayEnvironmentKey.expectedPromptEnemyID,
            environment: environment
        )
        let investigatorRaw = try required(
            ProductionAssignmentReplayEnvironmentKey.expectedPromptInvestigatorID,
            in: environment
        )
        guard let investigatorID = InvestigatorID(
            codingKey: AnyCodingKey(stringValue: investigatorRaw)
        ) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptInvestigatorID
            )
        }
        let backendRevision = try gitRevision(
            ProductionAssignmentReplayEnvironmentKey.expectedBackendRevision,
            environment: environment
        )
        let appleRevision = try gitRevision(
            ProductionAssignmentReplayEnvironmentKey.expectedAppleRevision,
            environment: environment
        )
        let contractRaw = try required(
            ProductionAssignmentReplayEnvironmentKey.expectedContractRevision,
            in: environment
        )
        let contractRevision: ContractRevision
        do {
            contractRevision = try ContractRevision(contractRaw)
        } catch {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedContractRevision
            )
        }
        guard contractRevision.description == contractRaw else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedContractRevision
            )
        }
        let catalogRevision = try required(
            ProductionAssignmentReplayEnvironmentKey.expectedCatalogRevision,
            in: environment
        )
        guard LocaleCatalogGrammar.isCatalogRevision(catalogRevision) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedCatalogRevision
            )
        }
        let promptDigest = try required(
            ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest,
            in: environment
        )
        guard LocaleCatalogGrammar.isSHA256Hex(promptDigest) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest
            )
        }
        let promptVersion = try canonicalInteger(
            ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion,
            in: environment,
            allowed: 0 ... (Int.max - 1)
        )
        let configuration = try ProductionAssignmentReplayConfiguration(
            checkpoint: checkpoint,
            deadlineSeconds: Double(deadline),
            serverProfile: profile,
            authToken: token,
            promptIdentity: ProductionAssignmentReplayPromptIdentity(
                gameID: gameID,
                ownerID: playerID,
                enemyID: enemyID,
                investigatorID: investigatorID
            ),
            expectedBackendRevision: backendRevision,
            expectedAppleRevision: appleRevision,
            expectedContractRevision: contractRevision,
            expectedCatalogRevision: catalogRevision,
            expectedPromptDigest: promptDigest,
            expectedPromptVersion: promptVersion
        )
        return (
            configuration,
            URL(fileURLWithPath: resultPath, isDirectory: false)
        )
    }

    static func validateKnownKeys(_ environment: [String: String]) throws {
        if let key = environment.keys.first(where: {
            $0.hasPrefix(ProductionAssignmentReplayEnvironmentKey.prefix)
                && !ProductionAssignmentReplayEnvironmentKey.known.contains($0)
        }) {
            throw AssignmentReplayConfigurationError.unknownEnvironmentKey(key)
        }
    }

    private static func required(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw AssignmentReplayConfigurationError.missingEnvironmentKey(key)
        }
        return value
    }

    private static func canonicalInteger(
        _ key: String,
        in environment: [String: String],
        allowed: ClosedRange<Int>
    ) throws -> Int {
        let raw = try required(key, in: environment)
        guard raw.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              raw == "0" || raw.first != "0",
              let value = Int(raw),
              allowed.contains(value)
        else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(key)
        }
        return value
    }

    private static func identifier<Tag: Sendable>(
        _: Identifier<Tag>.Type,
        key: String,
        environment: [String: String]
    ) throws -> Identifier<Tag> {
        let raw = try required(key, in: environment)
        guard let value = Identifier<Tag>(
            codingKey: AnyCodingKey(stringValue: raw)
        ) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(key)
        }
        return value
    }

    private static func gitRevision(
        _ key: String,
        environment: [String: String]
    ) throws -> String {
        let value = try required(key, in: environment)
        guard isLowercaseHex(value, count: 40) else {
            throw AssignmentReplayConfigurationError.invalidEnvironmentValue(key)
        }
        return value
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count
            && value.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
            }
    }
}

struct ProductionAssignmentReplayInvocation: Sendable {
    let configuration: ProductionAssignmentReplayConfiguration
    let resultURL: URL

    static func parse(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProductionAssignmentReplayInvocation? {
        guard environment.keys.contains(where: {
            $0.hasPrefix(ProductionAssignmentReplayEnvironmentKey.prefix)
        }) else {
            return nil
        }
        try ProductionAssignmentReplayConfiguration.validateKnownKeys(environment)
        if environment[ProductionAssignmentReplayEnvironmentKey.observedAppleRevision] != nil {
            throw AssignmentReplayConfigurationError.forbiddenEnvironmentKey(
                ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
            )
        }
        let values = try ProductionAssignmentReplayConfiguration
            .parseExternalValues(environment)
        return ProductionAssignmentReplayInvocation(
            configuration: values.configuration,
            resultURL: values.resultURL
        )
    }
}
