@testable import ArkhamHorrorShared
import Dispatch
import Foundation

// swiftlint:disable file_length

// swiftlint:disable:next type_name
enum ProductionAssignmentReplayCoordinatorError: Error, Equatable {
    case unknownEnvironmentKey(String)
    case missingEnvironmentKey(String)
    case forbiddenEnvironmentKey(String)
    case invalidEnvironmentValue(String)
    case insecureServerURL
    case appleRevisionMismatch
    case deadlineExpired
    case importFailed
    case importedGameMalformed
    case importedGameIdentityMismatch
    case importedPlayerMissing
    case duplicateImportedGame
    case checkpointAuthorityMismatch
    case authoritativeGameMalformed
    case outputValidationFailed
    case unsupportedHost
}

// swiftlint:disable:next type_name
enum AssignmentReplayCoordinatorEnvironmentKey {
    static let prefix = "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_"
    static let serverBaseURL = prefix + "SERVER_BASE_URL"
    static let serverProfileID = prefix + "SERVER_PROFILE_ID"
    static let checkpointPath = prefix + "CHECKPOINT_PATH"
    static let tokenPath = prefix + "TOKEN_PATH"
    static let outputDirectory = prefix + "OUTPUT_DIRECTORY"
    static let deadlineSeconds = prefix + "DEADLINE_SECONDS"
    static let expectedContractRevision =
        prefix + "EXPECTED_CONTRACT_REVISION"
    static let expectedCatalogRevision =
        prefix + "EXPECTED_CATALOG_REVISION"
    static let enemyID = prefix + "ENEMY_ID"
    static let investigatorID = prefix + "INVESTIGATOR_ID"
    static let observedAppleRevision = prefix + "OBSERVED_APPLE_REVISION"
    static let outputDevice = prefix + "OUTPUT_DEVICE"
    static let outputInode = prefix + "OUTPUT_INODE"
    static let deadlineUptimeNanoseconds =
        prefix + "DEADLINE_UPTIME_NANOSECONDS"

    static let parentOnly = Set([
        observedAppleRevision,
        outputDevice,
        outputInode,
        deadlineUptimeNanoseconds,
    ])

    static let known = parentOnly.union([
        serverBaseURL,
        serverProfileID,
        checkpointPath,
        tokenPath,
        outputDirectory,
        deadlineSeconds,
        expectedContractRevision,
        expectedCatalogRevision,
        enemyID,
        investigatorID,
    ])
}

struct AssignmentReplayCoordinatorDeadline: Sendable, Equatable {
    let uptimeNanoseconds: UInt64

    init(secondsFromNow seconds: Int) {
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds +
            UInt64(seconds) * 1_000_000_000
    }

    init(rawValue: String) throws {
        guard rawValue.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              rawValue.first != "0",
              let value = UInt64(rawValue)
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey
                        .deadlineUptimeNanoseconds
                )
        }
        uptimeNanoseconds = value
    }

    var rawValue: String {
        String(uptimeNanoseconds)
    }

    func remainingSeconds() throws -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard uptimeNanoseconds > now else {
            throw ProductionAssignmentReplayCoordinatorError.deadlineExpired
        }
        return Double(uptimeNanoseconds - now) / 1_000_000_000
    }
}

// swiftlint:disable:next type_body_length type_name
struct ProductionAssignmentReplayCoordinatorInvocation: Sendable {
    let serverProfile: ServerProfile
    let checkpointURL: URL
    let tokenURL: URL
    let outputDirectoryURL: URL
    let deadlineSeconds: Int
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let enemyID: EnemyID
    let investigatorID: InvestigatorID

    static func parse(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProductionAssignmentReplayCoordinatorInvocation? {
        guard environment.keys.contains(where: {
            $0.hasPrefix(AssignmentReplayCoordinatorEnvironmentKey.prefix)
        }) else {
            return nil
        }
        try validateKnownKeys(environment)
        let forbidden = AssignmentReplayCoordinatorEnvironmentKey.parentOnly
            .first(where: { environment[$0] != nil })
        if let forbidden {
            throw ProductionAssignmentReplayCoordinatorError
                .forbiddenEnvironmentKey(forbidden)
        }
        return try parseExternalValues(environment)
    }

    func childEnvironment(
        observedAppleRevision: String,
        outputIdentity: ProductionReplayParentIdentity,
        deadline: AssignmentReplayCoordinatorDeadline
    ) -> [String: String] {
        [
            AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL:
                serverProfile.endpointSummary,
            AssignmentReplayCoordinatorEnvironmentKey.serverProfileID:
                serverProfile.id.uuidString.lowercased(),
            AssignmentReplayCoordinatorEnvironmentKey.checkpointPath:
                checkpointURL.path,
            AssignmentReplayCoordinatorEnvironmentKey.tokenPath:
                tokenURL.path,
            AssignmentReplayCoordinatorEnvironmentKey.outputDirectory:
                outputDirectoryURL.path,
            AssignmentReplayCoordinatorEnvironmentKey.deadlineSeconds:
                String(deadlineSeconds),
            AssignmentReplayCoordinatorEnvironmentKey
                .expectedContractRevision:
                expectedContractRevision.description,
            AssignmentReplayCoordinatorEnvironmentKey
                .expectedCatalogRevision:
                expectedCatalogRevision,
            AssignmentReplayCoordinatorEnvironmentKey.enemyID:
                enemyID.codingKey.stringValue,
            AssignmentReplayCoordinatorEnvironmentKey.investigatorID:
                investigatorID.codingKey.stringValue,
            AssignmentReplayCoordinatorEnvironmentKey.observedAppleRevision:
                observedAppleRevision,
            AssignmentReplayCoordinatorEnvironmentKey.outputDevice:
                String(outputIdentity.device),
            AssignmentReplayCoordinatorEnvironmentKey.outputInode:
                String(outputIdentity.inode),
            AssignmentReplayCoordinatorEnvironmentKey
                .deadlineUptimeNanoseconds:
                deadline.rawValue,
        ]
    }

    // swiftlint:disable:next function_body_length
    fileprivate static func parseExternalValues(
        _ environment: [String: String]
    ) throws -> ProductionAssignmentReplayCoordinatorInvocation {
        let profile = try parseServerProfile(environment)
        let checkpointURL = try absoluteFileURL(
            key: AssignmentReplayCoordinatorEnvironmentKey.checkpointPath,
            environment: environment,
            permitsRoot: false
        )
        let tokenURL = try absoluteFileURL(
            key: AssignmentReplayCoordinatorEnvironmentKey.tokenPath,
            environment: environment,
            permitsRoot: false
        )
        let outputDirectoryURL = try absoluteFileURL(
            key: AssignmentReplayCoordinatorEnvironmentKey.outputDirectory,
            environment: environment,
            permitsRoot: false
        )
        let deadlineSeconds = try canonicalInteger(
            key: AssignmentReplayCoordinatorEnvironmentKey.deadlineSeconds,
            environment: environment,
            allowed: 1 ... Int(
                ProductionAssignmentReplayConfiguration
                    .maximumDeadlineSeconds
            )
        )
        let contractRevision = try contractRevision(environment)
        guard contractRevision == ContractPin.current.supportedSchemaRevision
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey
                        .expectedContractRevision
                )
        }
        let catalogRevision = try required(
            AssignmentReplayCoordinatorEnvironmentKey
                .expectedCatalogRevision,
            in: environment
        )
        guard LocaleCatalogGrammar.isCatalogRevision(catalogRevision) else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey
                        .expectedCatalogRevision
                )
        }
        return try ProductionAssignmentReplayCoordinatorInvocation(
            serverProfile: profile,
            checkpointURL: checkpointURL,
            tokenURL: tokenURL,
            outputDirectoryURL: outputDirectoryURL,
            deadlineSeconds: deadlineSeconds,
            expectedContractRevision: contractRevision,
            expectedCatalogRevision: catalogRevision,
            enemyID: identifier(
                EnemyID.self,
                key: AssignmentReplayCoordinatorEnvironmentKey.enemyID,
                environment: environment
            ),
            investigatorID: investigatorID(environment)
        )
    }

    static func validateKnownKeys(
        _ environment: [String: String]
    ) throws {
        if let key = environment.keys.first(where: {
            $0.hasPrefix(AssignmentReplayCoordinatorEnvironmentKey.prefix)
                && !AssignmentReplayCoordinatorEnvironmentKey.known
                .contains($0)
        }) {
            throw ProductionAssignmentReplayCoordinatorError
                .unknownEnvironmentKey(key)
        }
    }

    private static func parseServerProfile(
        _ environment: [String: String]
    ) throws -> ServerProfile {
        let rawURL = try required(
            AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL,
            in: environment
        )
        let profileIDRaw = try required(
            AssignmentReplayCoordinatorEnvironmentKey.serverProfileID,
            in: environment
        )
        guard let profileID = UUID(uuidString: profileIDRaw),
              profileID.uuidString.lowercased() == profileIDRaw
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.serverProfileID
                )
        }
        let profile: ServerProfile
        do {
            profile = try ServerProfile.custom(
                id: profileID,
                displayName: "Production assignment replay",
                rawURL: rawURL
            )
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL
                )
        }
        guard profile.endpointSummary == rawURL else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL
                )
        }
        if profile.baseURL.scheme == "http" {
            guard let host = profile.baseURL.host?.lowercased(),
                  host != "localhost",
                  ServerProfile.isLoopbackHost(host)
            else {
                throw ProductionAssignmentReplayCoordinatorError
                    .insecureServerURL
            }
        }
        return profile
    }

    private static func absoluteFileURL(
        key: String,
        environment: [String: String],
        permitsRoot: Bool
    ) throws -> URL {
        let rawValue = try required(key, in: environment)
        guard rawValue.hasPrefix("/"), !rawValue.contains("\0"),
              permitsRoot || rawValue != "/"
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(key)
        }
        return URL(fileURLWithPath: rawValue, isDirectory: false)
    }

    private static func contractRevision(
        _ environment: [String: String]
    ) throws -> ContractRevision {
        let rawValue = try required(
            AssignmentReplayCoordinatorEnvironmentKey
                .expectedContractRevision,
            in: environment
        )
        do {
            let revision = try ContractRevision(rawValue)
            guard revision.description == rawValue else {
                throw ProductionAssignmentReplayCoordinatorError
                    .invalidEnvironmentValue(
                        AssignmentReplayCoordinatorEnvironmentKey
                            .expectedContractRevision
                    )
            }
            return revision
        } catch let error as ProductionAssignmentReplayCoordinatorError {
            throw error
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey
                        .expectedContractRevision
                )
        }
    }

    private static func investigatorID(
        _ environment: [String: String]
    ) throws -> InvestigatorID {
        let rawValue = try required(
            AssignmentReplayCoordinatorEnvironmentKey.investigatorID,
            in: environment
        )
        guard let value = InvestigatorID(
            codingKey: AnyCodingKey(stringValue: rawValue)
        ) else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.investigatorID
                )
        }
        return value
    }

    private static func identifier<Tag: Sendable>(
        _: Identifier<Tag>.Type,
        key: String,
        environment: [String: String]
    ) throws -> Identifier<Tag> {
        let rawValue = try required(key, in: environment)
        guard let value = Identifier<Tag>(
            codingKey: AnyCodingKey(stringValue: rawValue)
        ) else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(key)
        }
        return value
    }

    private static func canonicalInteger(
        key: String,
        environment: [String: String],
        allowed: ClosedRange<Int>
    ) throws -> Int {
        let rawValue = try required(key, in: environment)
        guard rawValue.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              rawValue == "0" || rawValue.first != "0",
              let value = Int(rawValue),
              allowed.contains(value)
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(key)
        }
        return value
    }

    private static func required(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw ProductionAssignmentReplayCoordinatorError
                .missingEnvironmentKey(key)
        }
        return value
    }
}

// swiftlint:disable:next type_name
struct ProductionAssignmentReplayCoordinatorChildInvocation: Sendable {
    let invocation: ProductionAssignmentReplayCoordinatorInvocation
    let appleRevision: String
    let outputIdentity: ProductionReplayParentIdentity
    let deadline: AssignmentReplayCoordinatorDeadline

    static func parse(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProductionAssignmentReplayCoordinatorChildInvocation {
        try ProductionAssignmentReplayCoordinatorInvocation
            .validateKnownKeys(environment)
        let invocation =
            try ProductionAssignmentReplayCoordinatorInvocation
                .parseExternalValues(environment)
        let appleRevision = try required(
            AssignmentReplayCoordinatorEnvironmentKey.observedAppleRevision,
            environment: environment
        )
        guard ProductionAssignmentReplayConfiguration.isLowercaseHex(
            appleRevision,
            count: 40
        ) else {
            throw ProductionAssignmentReplayCoordinatorError
                .appleRevisionMismatch
        }
        let outputIdentity = try ProductionReplayParentIdentity(
            device: requiredInteger(
                AssignmentReplayCoordinatorEnvironmentKey.outputDevice,
                environment: environment,
                type: Int32.self
            ),
            inode: requiredInteger(
                AssignmentReplayCoordinatorEnvironmentKey.outputInode,
                environment: environment,
                type: UInt64.self
            )
        )
        let deadline = try AssignmentReplayCoordinatorDeadline(
            rawValue: required(
                AssignmentReplayCoordinatorEnvironmentKey
                    .deadlineUptimeNanoseconds,
                environment: environment
            )
        )
        _ = try deadline.remainingSeconds()
        return ProductionAssignmentReplayCoordinatorChildInvocation(
            invocation: invocation,
            appleRevision: appleRevision,
            outputIdentity: outputIdentity,
            deadline: deadline
        )
    }

    private static func required(
        _ key: String,
        environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw ProductionAssignmentReplayCoordinatorError
                .missingEnvironmentKey(key)
        }
        return value
    }

    private static func requiredInteger<Value: FixedWidthInteger>(
        _ key: String,
        environment: [String: String],
        type _: Value.Type
    ) throws -> Value {
        let rawValue = try required(key, environment: environment)
        guard rawValue.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              rawValue == "0" || rawValue.first != "0",
              let value = Value(rawValue),
              String(value) == rawValue
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(key)
        }
        return value
    }
}
