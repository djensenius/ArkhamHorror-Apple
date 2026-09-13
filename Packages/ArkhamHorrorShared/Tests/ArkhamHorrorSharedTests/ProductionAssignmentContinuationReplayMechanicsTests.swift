@testable import ArkhamHorrorShared
import Dispatch
import Foundation
import Testing

// swiftlint:disable file_length

private let replayAppleRevision = String(repeating: "a", count: 40)
private let replayCatalogRevision = "1." + String(repeating: "b", count: 32)
private let replayGameRevision = String(repeating: "c", count: 40)
private let replayCheckpointArtifactSHA256 = String(repeating: "d", count: 64)
private let replayCheckpointEnvelopeSHA256 = String(repeating: "e", count: 64)
private let replayBackendPromptSHA256 =
    "ffba40384536b2ed6ba5c3af3f765806c15c957fc8165754fc198c5cafe47c0a"

@Suite("Production assignment replay coordinator configuration")
// swiftlint:disable:next type_name
struct AssignmentReplayCoordinatorConfigurationTests {
    @Test("No coordinator environment leaves normal CI disabled")
    func absentConfigurationIsDisabled() throws {
        #expect(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: [:]
            ) == nil
        )
    }

    @Test("Canonical profile and typed inputs parse")
    func canonicalConfiguration() throws {
        let environment = coordinatorEnvironment()
        let invocation = try #require(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        )
        #expect(invocation.serverProfile.endpointSummary
            == "http://127.0.0.1:3002")
        #expect(invocation.deadlineSeconds == 30)
        #expect(invocation.expectedContractRevision
            == ContractPin.current.supportedSchemaRevision)
        #expect(invocation.enemyID == DamageAssignmentFixtures.enemyID)
        #expect(invocation.investigatorID
            == DamageAssignmentFixtures.investigatorID)
    }

    @Test(
        "Canonical HTTPS and literal loopback HTTP profiles parse",
        arguments: [
            "https://example.com",
            "http://127.0.0.2:3002",
            "http://[::1]:3002",
        ]
    )
    func acceptedServerURL(_ rawURL: String) throws {
        var environment = coordinatorEnvironment()
        environment[
            AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL
        ] = rawURL
        let invocation = try #require(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        )
        #expect(invocation.serverProfile.endpointSummary == rawURL)
    }

    @Test(
        "Remote cleartext, localhost, userinfo, query, fragment, and ambiguous authorities fail",
        arguments: [
            "http://example.com",
            "http://localhost:3002",
            "http://user@127.0.0.1:3002",
            "https://example.com?query=1",
            "https://example.com#fragment",
            "http://127.1:3002",
            "http://127%2e0%2e0%2e1:3002",
            "HTTP://127.0.0.1:3002",
            "https://example.com/",
        ]
    )
    func unsafeServerURL(_ rawURL: String) {
        var environment = coordinatorEnvironment()
        environment[
            AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL
        ] = rawURL
        #expect(throws: Error.self) {
            _ = try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        }
    }

    @Test("Profile validation happens before any credential path is required")
    func serverValidationPrecedesCredentialInput() {
        let environment = [
            AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL:
                "http://example.com",
            AssignmentReplayCoordinatorEnvironmentKey.serverProfileID:
                "00000000-0000-0000-0000-000000000777",
        ]
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError.self
        ) {
            _ = try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        }
    }

    @Test("Unknown and parent-only keys fail closed")
    func unknownOrParentOnlyKeys() {
        var environment = coordinatorEnvironment()
        let unknown =
            AssignmentReplayCoordinatorEnvironmentKey.prefix + "TYPO"
        environment[unknown] = "1"
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .unknownEnvironmentKey(unknown)
        ) {
            _ = try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        }

        environment = coordinatorEnvironment()
        environment[
            AssignmentReplayCoordinatorEnvironmentKey.observedAppleRevision
        ] = replayAppleRevision
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .forbiddenEnvironmentKey(
                    AssignmentReplayCoordinatorEnvironmentKey
                        .observedAppleRevision
                )
        ) {
            _ = try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: environment
            )
        }
    }

    @Test("Child device and inode identity use canonical decimal values")
    func canonicalChildIdentity() throws {
        let invocation = try #require(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: coordinatorEnvironment()
            )
        )
        var environment = invocation.childEnvironment(
            observedAppleRevision: replayAppleRevision,
            outputIdentity: ProductionReplayParentIdentity(
                device: 1,
                inode: 2
            ),
            deadline: AssignmentReplayCoordinatorDeadline(
                secondsFromNow: 30
            )
        )
        environment[AssignmentReplayCoordinatorEnvironmentKey.outputDevice] =
            "01"
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.outputDevice
                )
        ) {
            _ = try ProductionAssignmentReplayCoordinatorChildInvocation
                .parse(environment: environment)
        }
    }
}

@Suite("Production assignment replay secure input")
struct AssignmentReplaySecureInputTests {
    @Test("Checkpoint bytes are opaque and hash the exact file")
    func exactOpaqueCheckpointDigest() throws {
        let original = Data(#"{"replayCheckpoint":{"envelopeSha256":"caller"}}"#.utf8)
        let changed = original + Data([0x0A])
        let first = try AssignmentReplayCheckpointFile(bytes: original)
        let second = try AssignmentReplayCheckpointFile(bytes: changed)
        #expect(first.artifactSHA256
            == LocaleCatalogLoader.sha256Hex(original))
        #expect(second.artifactSHA256
            == LocaleCatalogLoader.sha256Hex(changed))
        #expect(first.artifactSHA256 != second.artifactSHA256)
    }

    @Test("Retained descriptors reject substitution and permit only one read")
    func retainedInputDescriptor() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let inputURL = scratch.directory.appendingPathComponent("input")
        try Data("trusted".utf8).write(to: inputURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: inputURL.path
        )
        let handle = try ProductionReplayFileSystem.openVerifiedInput(
            inputURL,
            maxByteCount: 64,
            permission: .ownerReadWriteOnly
        )
        #expect(try handle.readOnce() == Data("trusted".utf8))
        #expect(throws: ProductionReplayDriverError.inputAlreadyRead) {
            _ = try handle.readOnce()
        }

        let secondURL = scratch.directory.appendingPathComponent("second")
        try Data("original".utf8).write(to: secondURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: secondURL.path
        )
        let substituted = try ProductionReplayFileSystem.openVerifiedInput(
            secondURL,
            maxByteCount: 64
        )
        try FileManager.default.removeItem(at: secondURL)
        try Data("replacement".utf8).write(to: secondURL)
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try substituted.readOnce()
        }
    }

    @Test("Token input requires exact mode 0600")
    func strictTokenMode() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let tokenURL = scratch.directory.appendingPathComponent("token")
        try Data("secret".utf8).write(to: tokenURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: tokenURL.path
        )
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayFileSystem.openVerifiedInput(
                tokenURL,
                maxByteCount: 4097,
                permission: .ownerReadWriteOnly
            )
        }
    }
}

@Suite("Production assignment replay server authority")
struct AssignmentReplayServerAuthorityTests {
    @Test("Governed schema-v1 attestation decodes without structural loss")
    func governedAuthorityFixture() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "replay-attestation",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        let data = try Data(contentsOf: fixtureURL)
        let original = try LosslessJSONParser.parse(data)
        let attestation = try ContractJSON.decode(
            ProductionAssignmentReplayAttestation.self,
            from: data
        )
        let reencoded = try LosslessJSONParser.parse(
            ContractJSON.encode(attestation)
        )

        #expect(original == reencoded)
        guard case let .object(root) = original else {
            throw TestFailure()
        }
        #expect(root["checkpointProvenance"] == nil)
        #expect(root["validatedCheckpoint"] != nil)
        #expect(
            try attestation.importReceipt.computedSHA256()
                == attestation.importReceipt.receiptSHA256
        )
        #expect(
            attestation.schemaVersion ==
                ProductionAssignmentReplayAttestation.schemaVersion
        )
    }

    @Test("Pinned server validator authority is accepted")
    func validAuthority() throws {
        let request = try replayAttestationRequest()
        let attestation = try replayAttestation(request: request)
        try attestation.validate(request: request)
        #expect(attestation.checkpointValidation.backendBuild
            == attestation.serverBuild)
        #expect(attestation.checkpointValidation.canonicalEnvelopeSHA256
            == replayCheckpointEnvelopeSHA256)
    }

    @Test("Artifact echo and dirty build fail closed")
    func invalidBuildAuthority() throws {
        let request = try replayAttestationRequest()
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try replayAttestation(
                request: request,
                artifactSHA256: String(repeating: "f", count: 64)
            ).validate(request: request)
        }
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            let dirty = replayServerBuild(
                sourceClean: false,
                attestation: "unattested"
            )
            try replayAttestation(
                request: request,
                serverBuild: dirty
            ).validate(request: request)
        }
    }

    @Test("Mismatched live player, validated state, and receipt digest fail closed")
    func invalidImportReceiptAuthority() throws {
        let request = try replayAttestationRequest()
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try replayAttestation(
                request: request,
                livePlayerID: BoardTestFixtures.playerID("000000000002")
            ).validate(request: request)
        }
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try replayAttestation(
                request: request,
                receiptSHA256: String(repeating: "f", count: 64)
            ).validate(request: request)
        }
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try replayAttestation(
                request: request,
                receiptValidatedCheckpoint: replayValidatedCheckpoint(
                    promptDigest: String(repeating: "f", count: 64)
                )
            ).validate(request: request)
        }
    }

    @Test("Legacy echo-only attestation and unknown keys are malformed")
    func legacyOrUnknownAttestation() async throws {
        let request = try replayAttestationRequest()
        let url = try replayAttestationURL(request)
        let response = try jsonResponse(url: url)
        let legacy = GameLifecycleRecordingTransport(
            data: Data(
                #"{"schemaVersion":1,"checkpointEnvelopeSha256":"echo"}"#.utf8
            ),
            response: response
        )
        await #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMalformed
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: legacy
            ).fetch(request: request)
        }

        var value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(
                replayAttestation(request: request)
            )
        )
        guard case var .object(root) = value else {
            throw TestFailure()
        }
        root["callerProof"] = .bool(true)
        value = .object(root)
        let unknown = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(value),
            response: response
        )
        await #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMalformed
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: unknown
            ).fetch(request: request)
        }
    }

    @Test("Authenticated request carries no cookie state")
    func authenticatedRequest() async throws {
        let request = try replayAttestationRequest()
        let url = try replayAttestationURL(request)
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(
                replayAttestation(request: request)
            ),
            response: jsonResponse(url: url)
        )
        _ = try await AssignmentReplayAttestationClient(
            transport: transport
        ).fetch(request: request)
        let captured = try #require(await transport.capturedRequest)
        #expect(captured.url == url)
        #expect(captured.httpMethod == "GET")
        #expect(captured.httpShouldHandleCookies == false)
        #expect(captured.value(forHTTPHeaderField: "Authorization")
            == "Token unit-test-token")
    }
}

@Suite("Production assignment replay cases and evidence")
// swiftlint:disable:next type_body_length
struct AssignmentReplayCasesAndEvidenceTests {
    @Test("Both semantic source orders retain exact deltas")
    func checkpointSelection() {
        let damage =
            ProductionAssignmentReplayCheckpoint.damageFirstThenRemainingHorror
        #expect(damage.sourceIndex == 0)
        #expect(damage.selectedAssignmentKind == .damage)
        #expect(damage.nextAssignmentKind == .horror)
        #expect(damage.assignmentAfter == AssignmentReplayFields(
            assignedHealthDamage: 1,
            assignedSanityDamage: 0
        ))

        let horror =
            ProductionAssignmentReplayCheckpoint.horrorFirstThenRemainingDamage
        #expect(horror.sourceIndex == 1)
        #expect(horror.selectedAssignmentKind == .horror)
        #expect(horror.nextAssignmentKind == .damage)
        #expect(horror.assignmentAfter == AssignmentReplayFields(
            assignedHealthDamage: 0,
            assignedSanityDamage: 1
        ))
    }

    @Test("Canonical prompt digest matches the backend golden vector")
    func promptDigestMatchesBackendVector() throws {
        #expect(
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            ) == replayBackendPromptSHA256
        )
    }

    @MainActor
    @Test(
        "Both cases validate combined and remaining prompts",
        arguments: ProductionAssignmentReplayCheckpoint.allCases
    )
    func promptValidation(
        _ checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws {
        let starting = try replayStartingFixture(checkpoint: checkpoint)
        let before =
            try ProductionAssignmentReplayValidator.validateStartingPrompt(
                starting.prompt,
                projection: starting.projection,
                configuration: starting.configuration
            )
        let next = try replayNextFixture(checkpoint: checkpoint)
        let after =
            try ProductionAssignmentReplayValidator.validateNextPrompt(
                next.prompt,
                projection: next.projection,
                configuration: starting.configuration
            )
        #expect(before.assignmentBefore == checkpoint.assignmentBefore)
        #expect(after.assignmentAfter == checkpoint.assignmentAfter)
        #expect(
            try ProductionAssignmentReplayValidator.validateAssignmentDelta(
                before: before.assignmentBefore,
                after: after.assignmentAfter,
                checkpoint: checkpoint
            ) == checkpoint.assignmentDelta
        )
    }

    @MainActor
    @Test("Stale version, digest, and semantic source identity fail closed")
    // swiftlint:disable:next function_body_length
    func staleStartingIdentity() throws {
        let fixture = try replayStartingFixture()
        let configuration = fixture.configuration
        _ = try ProductionAssignmentReplayValidator.validateStartingPrompt(
            fixture.prompt,
            projection: fixture.projection,
            configuration: configuration
        )

        let staleVersion = try replayConfiguration(
            promptDigest: configuration.expectedPromptDigest,
            promptVersion: configuration.expectedPromptVersion + 1,
            playerID: configuration.promptIdentity.ownerID
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .startingPromptVersionMismatch
        ) {
            _ = try ProductionAssignmentReplayValidator
                .validateStartingPrompt(
                    fixture.prompt,
                    projection: fixture.projection,
                    configuration: staleVersion
                )
        }

        let wrongDigest = try replayConfiguration(
            promptDigest: String(repeating: "f", count: 64),
            playerID: configuration.promptIdentity.ownerID
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .startingPromptDigestMismatch
        ) {
            _ = try ProductionAssignmentReplayValidator
                .validateStartingPrompt(
                    fixture.prompt,
                    projection: fixture.projection,
                    configuration: wrongDigest
                )
        }

        let wrongSource = try replayConfiguration(
            promptDigest: configuration.expectedPromptDigest,
            playerID: configuration.promptIdentity.ownerID,
            enemyID: BoardTestFixtures.enemyID("000000000389")
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .startingPromptShapeMismatch
        ) {
            _ = try ProductionAssignmentReplayValidator
                .validateStartingPrompt(
                    fixture.prompt,
                    projection: fixture.projection,
                    configuration: wrongSource
                )
        }
    }

    @MainActor
    @Test("Authoritative game revision, game, and player fail closed")
    // swiftlint:disable:next function_body_length
    func authoritativeIdentity() throws {
        let fixture = try replayStartingFixture()
        let configuration = fixture.configuration
        let valid = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: configuration.promptIdentity.gameID,
            gameRevision: configuration.attestation.gameRevision,
            playerID: configuration.promptIdentity.ownerID,
            projection: fixture.projection
        )
        try AssignmentReplayAuthoritativeValidator.validate(
            valid,
            projection: fixture.projection,
            configuration: configuration,
            attestation: configuration.attestation,
            requiresPlayerIdentity: true
        )

        let wrongRevision = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: valid.gameID,
            gameRevision: String(repeating: "f", count: 40),
            playerID: valid.playerID,
            projection: valid.projection
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .authoritativeGameRevisionMismatch
        ) {
            try AssignmentReplayAuthoritativeValidator.validate(
                wrongRevision,
                projection: fixture.projection,
                configuration: configuration,
                attestation: configuration.attestation,
                requiresPlayerIdentity: true
            )
        }

        let wrongGame = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: BoardTestFixtures.gameID("000000000901"),
            gameRevision: valid.gameRevision,
            playerID: valid.playerID,
            projection: valid.projection
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .authoritativeGameIdentityMismatch
        ) {
            try AssignmentReplayAuthoritativeValidator.validate(
                wrongGame,
                projection: fixture.projection,
                configuration: configuration,
                attestation: configuration.attestation,
                requiresPlayerIdentity: true
            )
        }

        let wrongPlayer = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: valid.gameID,
            gameRevision: valid.gameRevision,
            playerID: BoardTestFixtures.playerID("000000000002"),
            projection: valid.projection
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .authoritativePlayerIdentityMismatch
        ) {
            try AssignmentReplayAuthoritativeValidator.validate(
                wrongPlayer,
                projection: fixture.projection,
                configuration: configuration,
                attestation: configuration.attestation,
                requiresPlayerIdentity: true
            )
        }
    }

    @MainActor
    @Test("Retryable resolution requires canonical send and authoritative next proof")
    func retryableResolutionProofs() throws {
        let starting = try replayStartingFixture()
        let expectedAnswer = BasicChoiceAnswer(
            choice: starting.configuration.checkpoint.sourceIndex,
            playerID: starting.configuration.promptIdentity.ownerID,
            questionVersion: starting.configuration.expectedPromptVersion
        )
        let expectedData = try ContractJSON.encode(expectedAnswer)
        let sendProof =
            try AssignmentReplaySubmissionValidator.proveCanonicalSend(
                sentAnswers: [expectedData],
                expectedData: expectedData,
                expectedAnswer: expectedAnswer
            )
        let nextFixture = try replayNextFixture(
            checkpoint: starting.configuration.checkpoint
        )
        let nextProof =
            try ProductionAssignmentReplayValidator.validateNextPrompt(
                nextFixture.prompt,
                projection: nextFixture.projection,
                configuration: starting.configuration
            )
        try AssignmentReplaySubmissionValidator.validateResolvedSubmission(
            .retryableFailure,
            sendProof: sendProof,
            nextProof: nextProof
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .sentAnswerCountMismatch
        ) {
            _ = try AssignmentReplaySubmissionValidator.proveCanonicalSend(
                sentAnswers: [],
                expectedData: expectedData,
                expectedAnswer: expectedAnswer
            )
        }
        #expect(
            throws: ProductionAssignmentReplayError.answerSubmissionFailed
        ) {
            try AssignmentReplaySubmissionValidator
                .validateResolvedSubmission(
                    .alreadyPending,
                    sendProof: sendProof,
                    nextProof: nextProof
                )
        }
    }

    @Test("Evidence is canonical and records server validator authority")
    func canonicalEvidence() throws {
        let configuration = try replayConfiguration()
        let evidence = try replayEvidence(configuration: configuration)
        let artifact = try AssignmentReplayEvidenceArtifact(
            evidence: evidence
        )
        let data = try artifact.validatedData()
        #expect(
            try AssignmentReplayEvidenceArtifact.decodeAndValidate(data)
                == artifact
        )
        #expect(evidence.schemaVersion == "4.0.0")
        #expect(evidence.checkpoint.validator
            == AssignmentReplayValidatedCheckpoint.validator)
        #expect(evidence.checkpoint.canonicalEnvelopeSHA256
            == replayCheckpointEnvelopeSHA256)
        #expect(evidence.checkpoint.backendBuild
            == evidence.revisions.serverBuild)

        var trailingNewline = data
        trailingNewline.append(0x0A)
        #expect(
            throws: ProductionAssignmentReplayEvidenceError
                .nonCanonicalEncoding
        ) {
            _ = try AssignmentReplayEvidenceArtifact.decodeAndValidate(
                trailingNewline
            )
        }

        var value = try ContractJSON.decode(JSONValue.self, from: data)
        guard case var .object(root) = value else {
            throw TestFailure()
        }
        root["evidenceCanonicalSHA256"] =
            .string(String(repeating: "0", count: 64))
        value = .object(root)
        let tampered = try ContractJSON.decode(
            AssignmentReplayEvidenceArtifact.self,
            from: LosslessJSONSerializer.serialize(value)
        )
        #expect(
            throws: ProductionAssignmentReplayEvidenceError.digestMismatch
        ) {
            _ = try tampered.validatedData()
        }
    }
}

@MainActor
@Suite("Production assignment replay self-test harness")
// swiftlint:disable:next type_body_length
struct AssignmentReplayCoordinatorSelfTestSuite {
    @Test("Two cases are fresh, ordered, and credential-free outside Swift")
    func successfulTwoCaseRun() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes
        )
        let runner = CoordinatorCaseRunnerProbe()
        let manifest =
            try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try runner.run($0) }
            )
        try manifest.manifest.validate()
        #expect(await backend.importCount == 2)
        #expect(runner.cases == ProductionAssignmentReplayCheckpoint.allCases)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ) == [
                AssignmentReplayCoordinatorDriver.damageEvidenceName,
                AssignmentReplayCoordinatorDriver.horrorEvidenceName,
            ]
        )
    }

    @Test("First controller case failure is fail-fast after two-case preflight")
    func firstCaseFailure() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes
        )
        let runner = CoordinatorCaseRunnerProbe(
            failingCase: .damageFirstThenRemainingHorror
        )
        await #expect(throws: TestFailure.self) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try runner.run($0) }
            )
        }
        #expect(await backend.importCount == 2)
        #expect(runner.cases == [.damageFirstThenRemainingHorror])
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ).isEmpty
        )
    }

    @Test("Second case failure removes first-case evidence")
    func secondCaseFailure() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes
        )
        let runner = CoordinatorCaseRunnerProbe(
            failingCase: .horrorFirstThenRemainingDamage
        )
        await #expect(throws: TestFailure.self) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try runner.run($0) }
            )
        }
        #expect(await backend.importCount == 2)
        #expect(runner.cases == ProductionAssignmentReplayCheckpoint.allCases)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ).isEmpty
        )
    }

    @Test("Tampered export or provenance is rejected by backend validator")
    func tamperedCheckpointRejected() async throws {
        let fixture = try coordinatorHarnessFixture(
            checkpointBytes: Data(#"{"campaignPlayers":["tampered"]}"#.utf8)
        )
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: Data(#"{"campaignPlayers":[]}"#.utf8)
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError.importFailed
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try replayEvidence(configuration: $0) }
            )
        }
        #expect(await backend.importCount == 1)
    }

    @Test("Imported game ID must match the authoritative snapshot")
    func importedGameIdentityMismatch() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes,
            mismatchesFirstGameIdentity: true
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .importedGameIdentityMismatch
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try replayEvidence(configuration: $0) }
            )
        }
        #expect(await backend.importCount == 1)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ).isEmpty
        )
    }

    @Test("Duplicate games and divergent validator receipts fail closed")
    // swiftlint:disable:next function_body_length
    func crossCaseIdentity() async throws {
        let duplicateFixture = try coordinatorHarnessFixture()
        defer { duplicateFixture.cleanup() }
        let duplicateBackend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: duplicateFixture.checkpointBytes,
            duplicateGame: true
        )
        var duplicateRunnerInvocationCount = 0
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .duplicateImportedGame
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: duplicateFixture.child,
                backend: duplicateBackend,
                caseRunner: {
                    duplicateRunnerInvocationCount += 1
                    return try replayEvidence(configuration: $0)
                }
            )
        }
        #expect(duplicateRunnerInvocationCount == 0)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                duplicateFixture.output
            ).isEmpty
        )

        let authorityFixture = try coordinatorHarnessFixture()
        defer { authorityFixture.cleanup() }
        let authorityBackend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: authorityFixture.checkpointBytes,
            divergesSecondAuthority: true
        )
        var authorityRunnerInvocationCount = 0
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .checkpointAuthorityMismatch
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: authorityFixture.child,
                backend: authorityBackend,
                caseRunner: {
                    authorityRunnerInvocationCount += 1
                    return try replayEvidence(configuration: $0)
                }
            )
        }
        #expect(authorityRunnerInvocationCount == 0)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                authorityFixture.output
            ).isEmpty
        )
    }

    @Test("Expired global deadline prevents all import work")
    func expiredDeadline() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes
        )
        let expired = try ProductionAssignmentReplayCoordinatorChildInvocation(
            invocation: fixture.child.invocation,
            appleRevision: fixture.child.appleRevision,
            outputIdentity: fixture.child.outputIdentity,
            deadline: AssignmentReplayCoordinatorDeadline(
                rawValue: String(
                    DispatchTime.now().uptimeNanoseconds - 1
                )
            )
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError.deadlineExpired
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: expired,
                backend: backend,
                caseRunner: { try replayEvidence(configuration: $0) }
            )
        }
        #expect(await backend.importCount == 0)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ).isEmpty
        )
    }

    @Test("Output path substitution is rejected without touching replacement")
    func outputSubstitutionRejected() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let outputURL = scratch.directory.appendingPathComponent("output")
        let output = try ProductionReplayFileSystem.createPrivateDirectory(
            outputURL
        )
        let moved = scratch.directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: outputURL, to: moved)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: outputURL.path
        )
        #expect(throws: ProductionReplayDriverError.unsafeResultParent) {
            try ProductionReplayFileSystem.writeOwnedFile(
                Data("evidence".utf8),
                named: "damage-first.json",
                in: output
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: outputURL.path
            ).isEmpty
        )
    }

    @Test("Child rejects a nonempty retained output before any import")
    func nonemptyChildOutputRejected() async throws {
        let fixture = try coordinatorHarnessFixture()
        defer { fixture.cleanup() }
        try ProductionReplayFileSystem.writeOwnedFile(
            Data("stale".utf8),
            named: "stale",
            in: fixture.output
        )
        let backend = FakeAssignmentReplayCoordinatorBackend(
            approvedCheckpoint: fixture.checkpointBytes
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        ) {
            _ = try await AssignmentReplayCoordinatorSelfTestHarness.run(
                child: fixture.child,
                backend: backend,
                caseRunner: { try replayEvidence(configuration: $0) }
            )
        }
        #expect(await backend.importCount == 0)
        #expect(
            try ProductionReplayFileSystem.listOwnedDirectoryNames(
                fixture.output
            ) == ["stale"]
        )
    }
}

@Suite("Production assignment replay coordinator driver wiring")
// swiftlint:disable:next type_name
struct AssignmentReplayCoordinatorDriverWiringTests {
    @Test("One globally bounded victim receives paths, never token contents")
    func globalVictimWiring() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let invocation = try #require(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: coordinatorEnvironment(
                    checkpointPath: scratch.directory
                        .appendingPathComponent("checkpoint").path,
                    tokenPath: scratch.directory
                        .appendingPathComponent("token").path,
                    outputPath: scratch.directory
                        .appendingPathComponent("output").path
                )
            )
        )
        var capturedEnvironment: [String: String] = [:]
        #expect(throws: SubprocessDeadlineGuardError.self) {
            _ = try AssignmentReplayCoordinatorDriver.run(
                invocation: invocation,
                hostArguments: ["/test-host", "--filter", "old"],
                appleRevisionProvider: { replayAppleRevision },
                deadlineRunner: { filter, environment, deadline, _ in
                    #expect(try filter ==
                        (AssignmentReplayCoordinatorDriver.victim())
                        .exactFilter)
                    #expect(deadline > 0 && deadline <= 30)
                    capturedEnvironment = environment
                    throw SubprocessDeadlineGuardError.childFailed(
                        exitCode: 7
                    )
                }
            )
        }
        #expect(capturedEnvironment[
            AssignmentReplayCoordinatorEnvironmentKey.tokenPath
        ] == invocation.tokenURL.path)
        #expect(!capturedEnvironment.values.contains("unit-test-token"))
        #expect(!FileManager.default.fileExists(
            atPath: invocation.outputDirectoryURL.path
        ))
    }

    @Test("Preexisting output is rejected without overwrite")
    func staleOutputRejected() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let output = scratch.directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        let stale = output.appendingPathComponent("damage-first.json")
        try Data("stale".utf8).write(to: stale)
        let invocation = try #require(
            try ProductionAssignmentReplayCoordinatorInvocation.parse(
                environment: coordinatorEnvironment(
                    outputPath: output.path
                )
            )
        )
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try AssignmentReplayCoordinatorDriver.run(
                invocation: invocation,
                appleRevisionProvider: { replayAppleRevision }
            )
        }
        #expect(try Data(contentsOf: stale) == Data("stale".utf8))
    }
}

private actor FakeAssignmentReplayCoordinatorBackend: AssignmentReplayCoordinatorBackend {
    let approvedCheckpoint: Data
    let duplicateGame: Bool
    let divergesSecondAuthority: Bool
    let mismatchesFirstGameIdentity: Bool
    private(set) var importCount = 0
    private var games: [GameID: GetGameEnvelope] = [:]

    init(
        approvedCheckpoint: Data,
        duplicateGame: Bool = false,
        divergesSecondAuthority: Bool = false,
        mismatchesFirstGameIdentity: Bool = false
    ) {
        self.approvedCheckpoint = approvedCheckpoint
        self.duplicateGame = duplicateGame
        self.divergesSecondAuthority = divergesSecondAuthority
        self.mismatchesFirstGameIdentity = mismatchesFirstGameIdentity
    }

    func importCheckpoint(
        _ checkpoint: AssignmentReplayCheckpointFile,
        investigatorID _: InvestigatorID,
        profile _: ServerProfile,
        token _: String
    ) async throws -> GameID {
        importCount += 1
        guard checkpoint.bytes == approvedCheckpoint else {
            throw ProductionAssignmentReplayCoordinatorError.importFailed
        }
        let gameID = BoardTestFixtures.gameID(
            duplicateGame || importCount == 1
                ? "000000000101"
                : "000000000102"
        )
        let playerID = BoardTestFixtures.playerID(
            importCount == 1 ? "000000000201" : "000000000202"
        )
        let authoritativeGameID =
            mismatchesFirstGameIdentity && importCount == 1
                ? BoardTestFixtures.gameID("000000000199")
                : gameID
        games[gameID] = try await replayImportedGame(
            gameID: authoritativeGameID,
            playerID: playerID
        )
        return gameID
    }

    func getGame(
        _ gameID: GameID,
        profile _: ServerProfile,
        token _: String
    ) async throws -> GetGameEnvelope {
        guard let game = games[gameID] else {
            throw ProductionAssignmentReplayCoordinatorError
                .authoritativeGameMalformed
        }
        return game
    }

    func fetchAttestation(
        _ request: AssignmentReplayAttestationRequest
    ) async throws -> ProductionAssignmentReplayAttestation {
        try replayAttestation(
            request: request,
            canonicalEnvelopeSHA256:
            divergesSecondAuthority &&
                request.gameID ==
                BoardTestFixtures.gameID("000000000102")
                ? String(repeating: "f", count: 64)
                : replayCheckpointEnvelopeSHA256
        )
    }
}

@MainActor
private final class CoordinatorCaseRunnerProbe {
    private(set) var cases: [ProductionAssignmentReplayCheckpoint] = []
    let failingCase: ProductionAssignmentReplayCheckpoint?

    init(
        failingCase: ProductionAssignmentReplayCheckpoint? = nil
    ) {
        self.failingCase = failingCase
    }

    func run(
        _ configuration: ProductionAssignmentReplayConfiguration
    ) throws -> ProductionAssignmentReplayEvidence {
        cases.append(configuration.checkpoint)
        if configuration.checkpoint == failingCase {
            throw TestFailure()
        }
        return try replayEvidence(configuration: configuration)
    }
}

private struct CoordinatorHarnessFixture {
    let scratch: URL
    let output: ProductionReplayOwnedDirectory
    let child: ProductionAssignmentReplayCoordinatorChildInvocation
    let checkpointBytes: Data

    func cleanup() {
        try? ProductionReplayFileSystem.removeOwnedDirectory(output)
        try? FileManager.default.removeItem(at: scratch)
    }
}

private func coordinatorHarnessFixture(
    checkpointBytes: Data = Data(#"{"checkpoint":"opaque"}"#.utf8)
) throws -> CoordinatorHarnessFixture {
    let scratch = try makeScratch().directory
    let checkpointURL = scratch.appendingPathComponent("checkpoint")
    let tokenURL = scratch.appendingPathComponent("token")
    let outputURL = scratch.appendingPathComponent("output")
    try checkpointBytes.write(to: checkpointURL)
    try Data("unit-test-token\n".utf8).write(to: tokenURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: checkpointURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: tokenURL.path
    )
    let output = try ProductionReplayFileSystem.createPrivateDirectory(
        outputURL
    )
    let invocation = try ProductionAssignmentReplayCoordinatorInvocation(
        serverProfile: replayServerProfile(),
        checkpointURL: checkpointURL,
        tokenURL: tokenURL,
        outputDirectoryURL: outputURL,
        deadlineSeconds: 30,
        expectedContractRevision:
        ContractPin.current.supportedSchemaRevision,
        expectedCatalogRevision: replayCatalogRevision,
        enemyID: DamageAssignmentFixtures.enemyID,
        investigatorID: DamageAssignmentFixtures.investigatorID
    )
    let child = ProductionAssignmentReplayCoordinatorChildInvocation(
        invocation: invocation,
        appleRevision: replayAppleRevision,
        outputIdentity: output.identity,
        deadline: AssignmentReplayCoordinatorDeadline(secondsFromNow: 30)
    )
    return CoordinatorHarnessFixture(
        scratch: scratch,
        output: output,
        child: child,
        checkpointBytes: checkpointBytes
    )
}

private func coordinatorEnvironment(
    checkpointPath: String = "/private/checkpoint.json",
    tokenPath: String = "/private/token",
    outputPath: String = "/private/output"
) -> [String: String] {
    [
        AssignmentReplayCoordinatorEnvironmentKey.serverBaseURL:
            "http://127.0.0.1:3002",
        AssignmentReplayCoordinatorEnvironmentKey.serverProfileID:
            "00000000-0000-0000-0000-000000000777",
        AssignmentReplayCoordinatorEnvironmentKey.checkpointPath:
            checkpointPath,
        AssignmentReplayCoordinatorEnvironmentKey.tokenPath:
            tokenPath,
        AssignmentReplayCoordinatorEnvironmentKey.outputDirectory:
            outputPath,
        AssignmentReplayCoordinatorEnvironmentKey.deadlineSeconds: "30",
        AssignmentReplayCoordinatorEnvironmentKey
            .expectedContractRevision:
            ContractPin.current.supportedSchemaRevision.description,
        AssignmentReplayCoordinatorEnvironmentKey
            .expectedCatalogRevision:
            replayCatalogRevision,
        AssignmentReplayCoordinatorEnvironmentKey.enemyID:
            DamageAssignmentFixtures.enemyID.codingKey.stringValue,
        AssignmentReplayCoordinatorEnvironmentKey.investigatorID:
            DamageAssignmentFixtures.investigatorID.codingKey.stringValue,
    ]
}

private func replayServerProfile() throws -> ServerProfile {
    try ServerProfile.custom(
        id: #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000777")
        ),
        displayName: "Production assignment replay",
        rawURL: "http://127.0.0.1:3002"
    )
}

private func replayServerBuild(
    sourceSHA256: String = String(repeating: "2", count: 64),
    sourceClean: Bool = true,
    attestation: String = "git-clean"
) -> AssignmentReplayServerBuildIdentity {
    AssignmentReplayServerBuildIdentity(
        gitRevision: ContractPin.current.backendCommit,
        gitTree: String(repeating: "1", count: 40),
        sourceSHA256: sourceSHA256,
        sourceClean: sourceClean,
        attestation: attestation
    )
}

private func replayValidatedCheckpoint(
    promptDigest: String,
    promptVersion: Int = 6,
    checkpointPlayerID: PlayerID =
        BoardTestFixtures.playerID("000000000001")
) -> AssignmentReplayServerValidatedCheckpoint {
    AssignmentReplayServerValidatedCheckpoint(
        schemaVersion:
        AssignmentReplayServerValidatedCheckpoint.schemaVersion,
        contractSchemaRevision:
        ContractPin.current.supportedSchemaRevision.description,
        prompt: AssignmentReplayServerValidatedPrompt(
            questionVersion: promptVersion,
            playerID: checkpointPlayerID,
            promptTag:
            BasicChoiceQuestionKind.questionWithSource.rawValue,
            promptSHA256: promptDigest
        ),
        checkpointGameSHA256: String(repeating: "5", count: 64),
        checkpointQueueSHA256: String(repeating: "6", count: 64)
    )
}

private func replayAttestationRequest(
    gameID: GameID = BoardTestFixtures.gameID(),
    playerID: PlayerID =
        BoardTestFixtures.playerID("000000000001"),
    investigatorID: InvestigatorID =
        DamageAssignmentFixtures.investigatorID,
    artifactSHA256: String = replayCheckpointArtifactSHA256
) throws -> AssignmentReplayAttestationRequest {
    try AssignmentReplayAttestationRequest(
        serverProfile: replayServerProfile(),
        authToken: "unit-test-token",
        gameID: gameID,
        playerID: playerID,
        investigatorID: investigatorID,
        checkpointArtifactSHA256: artifactSHA256
    )
}

private struct ReplayReceiptFixtureInput {
    let request: AssignmentReplayAttestationRequest
    let artifactSHA256: String?
    let serverBuild: AssignmentReplayServerBuildIdentity
    let canonicalEnvelopeSHA256: String
    let validatedCheckpoint: AssignmentReplayServerValidatedCheckpoint
    let livePlayerID: PlayerID?
    let receiptSHA256: String?
}

private func replayAttestation(
    request: AssignmentReplayAttestationRequest,
    artifactSHA256: String? = nil,
    serverBuild: AssignmentReplayServerBuildIdentity =
        replayServerBuild(),
    canonicalEnvelopeSHA256: String =
        replayCheckpointEnvelopeSHA256,
    promptDigest: String? = nil,
    promptVersion: Int = 6,
    validatedCheckpoint: AssignmentReplayServerValidatedCheckpoint? = nil,
    receiptValidatedCheckpoint:
    AssignmentReplayServerValidatedCheckpoint? = nil,
    livePlayerID: PlayerID? = nil,
    receiptSHA256: String? = nil
) throws -> ProductionAssignmentReplayAttestation {
    let digest = promptDigest ?? replayBackendPromptSHA256
    let checkpoint = validatedCheckpoint ?? replayValidatedCheckpoint(
        promptDigest: digest,
        promptVersion: promptVersion
    )
    let receipt = try replayImportReceipt(
        ReplayReceiptFixtureInput(
            request: request,
            artifactSHA256: artifactSHA256,
            serverBuild: serverBuild,
            canonicalEnvelopeSHA256: canonicalEnvelopeSHA256,
            validatedCheckpoint:
            receiptValidatedCheckpoint ?? checkpoint,
            livePlayerID: livePlayerID,
            receiptSHA256: receiptSHA256
        )
    )
    return ProductionAssignmentReplayAttestation(
        schemaVersion: ProductionAssignmentReplayAttestation.schemaVersion,
        gameID: request.gameID,
        gameGitRevision: replayGameRevision,
        checkpointSHA256:
        artifactSHA256 ?? request.checkpointArtifactSHA256,
        canonicalEnvelopeSHA256: canonicalEnvelopeSHA256,
        validatedCheckpoint: checkpoint,
        runningServerBuild: serverBuild,
        importReceipt: receipt
    )
}

private func replayImportReceipt(
    _ input: ReplayReceiptFixtureInput
) throws -> AssignmentReplayImportReceipt {
    let remappings = [
        AssignmentReplayPlayerRemapping(
            investigatorID: input.request.investigatorID,
            checkpointPlayerID: input.validatedCheckpoint.prompt.playerID,
            importedPlayerID: input.request.playerID,
            livePlayerID: input.livePlayerID ?? input.request.playerID,
            stateRemapped: true
        ),
    ]
    let receiptWithoutDigest = AssignmentReplayImportReceipt(
        schemaVersion: AssignmentReplayImportReceipt.schemaVersion,
        gameID: input.request.gameID,
        gameGitRevision: replayGameRevision,
        backendBuild: input.serverBuild,
        checkpointSHA256:
        input.artifactSHA256 ?? input.request.checkpointArtifactSHA256,
        canonicalEnvelopeSHA256: input.canonicalEnvelopeSHA256,
        validatedCheckpoint: input.validatedCheckpoint,
        playerRemappings: remappings,
        receiptSHA256: ""
    )
    return try AssignmentReplayImportReceipt(
        schemaVersion: receiptWithoutDigest.schemaVersion,
        gameID: receiptWithoutDigest.gameID,
        gameGitRevision: receiptWithoutDigest.gameGitRevision,
        backendBuild: receiptWithoutDigest.backendBuild,
        checkpointSHA256: receiptWithoutDigest.checkpointSHA256,
        canonicalEnvelopeSHA256:
        receiptWithoutDigest.canonicalEnvelopeSHA256,
        validatedCheckpoint:
        receiptWithoutDigest.validatedCheckpoint,
        playerRemappings: receiptWithoutDigest.playerRemappings,
        receiptSHA256:
        input.receiptSHA256 ?? receiptWithoutDigest.computedSHA256()
    )
}

private func replayConfiguration(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror,
    promptDigest: String? = nil,
    promptVersion: Int = 6,
    gameID: GameID = BoardTestFixtures.gameID(),
    playerID: PlayerID =
        BoardTestFixtures.playerID("000000000001"),
    enemyID: EnemyID = DamageAssignmentFixtures.enemyID,
    artifactSHA256: String = replayCheckpointArtifactSHA256
) throws -> ProductionAssignmentReplayConfiguration {
    let request = try replayAttestationRequest(
        gameID: gameID,
        playerID: playerID,
        artifactSHA256: artifactSHA256
    )
    let digest = promptDigest ?? replayBackendPromptSHA256
    return try ProductionAssignmentReplayConfiguration(
        checkpoint: checkpoint,
        deadlineSeconds: 30,
        serverProfile: request.serverProfile,
        authToken: request.authToken,
        promptIdentity: ProductionAssignmentReplayPromptIdentity(
            gameID: gameID,
            ownerID: playerID,
            enemyID: enemyID,
            investigatorID: DamageAssignmentFixtures.investigatorID
        ),
        expectedAppleRevision: replayAppleRevision,
        expectedContractRevision:
        ContractPin.current.supportedSchemaRevision,
        expectedCatalogRevision: replayCatalogRevision,
        attestation: replayAttestation(
            request: request,
            promptDigest: digest,
            promptVersion: promptVersion
        )
    )
}

// swiftlint:disable:next function_body_length
private func replayEvidence(
    configuration: ProductionAssignmentReplayConfiguration
) throws -> ProductionAssignmentReplayEvidence {
    let checkpoint = configuration.checkpoint
    let authority = configuration.validatedCheckpoint
    return ProductionAssignmentReplayEvidence(
        schemaVersion: ProductionAssignmentReplayEvidence
            .currentSchemaVersion,
        checkpoint: AssignmentReplayCheckpointEvidence(
            caseName: checkpoint.rawValue,
            validator: authority.validator,
            validationStatus: authority.validationStatus,
            playerID: authority.checkpointPlayerID,
            questionVersion: authority.questionVersion,
            promptCanonicalSHA256: authority.promptSHA256,
            artifactSHA256: authority.artifactSHA256,
            canonicalEnvelopeSHA256: authority.canonicalEnvelopeSHA256,
            backendBuild: authority.backendBuild,
            checkpointGameSHA256: authority.checkpointGameSHA256,
            checkpointQueueSHA256: authority.checkpointQueueSHA256
        ),
        source: ProductionAssignmentReplaySourceEvidence(
            gameID: configuration.promptIdentity.gameID,
            playerID: configuration.promptIdentity.ownerID,
            promptTag: BasicChoiceQuestionKind.questionWithSource.rawValue,
            sourceTag: "EnemyAttackSource",
            enemyID: configuration.promptIdentity.enemyID,
            investigatorID: configuration.promptIdentity.investigatorID,
            promptVersion: authority.questionVersion,
            promptCanonicalSHA256: authority.promptSHA256,
            selectedAssignment:
            checkpoint.selectedAssignmentKind.productionReplayName,
            sourceIndex: checkpoint.sourceIndex
        ),
        answer: BasicChoiceAnswer(
            choice: checkpoint.sourceIndex,
            playerID: configuration.promptIdentity.ownerID,
            questionVersion: authority.questionVersion
        ),
        controller: AssignmentReplayControllerEvidence(
            jumpToActivePromptHandled: true,
            focusAfterJump: BoardFocusID.promptChoice(0).rawValue,
            movedToSelectedSourceIndex: checkpoint.sourceIndex == 1,
            focusBeforePrimaryAction:
            BoardFocusID.promptChoice(checkpoint.sourceIndex).rawValue,
            primaryActionHandled: true
        ),
        assignmentBefore: checkpoint.assignmentBefore,
        assignmentAfter: checkpoint.assignmentAfter,
        assignmentDelta: checkpoint.assignmentDelta,
        nextPrompt: AssignmentReplayNextPromptEvidence(
            promptTag: BasicChoiceQuestionKind.questionWithSource.rawValue,
            sourceTag: "EnemyAttackSource",
            assignment:
            checkpoint.nextAssignmentKind.productionReplayName,
            version: authority.questionVersion + 1,
            canonicalSHA256: String(repeating: "f", count: 64)
        ),
        revisions: AssignmentReplayRevisionEvidence(
            serverBuild: configuration.attestation.serverBuild,
            game: configuration.attestation.gameRevision,
            apple: configuration.expectedAppleRevision,
            contract: configuration.expectedContractRevision,
            catalog: configuration.expectedCatalogRevision
        )
    )
}

private struct AssignmentReplayStartingFixture {
    let prompt: BasicChoicePromptPresentation
    let projection: BoardProjection
    let configuration: ProductionAssignmentReplayConfiguration
}

@MainActor
private func replayStartingFixture(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror
) throws -> AssignmentReplayStartingFixture {
    let envelope = try AppModelLiveGameTests().damageAssignmentEnvelope()
    let playerID = try #require(envelope.playerID)
    let raw = try DamageAssignmentFixtures.value()
    let payload = try DamageAssignmentFixtures.payload(raw)
    let configuration = try replayConfiguration(
        checkpoint: checkpoint,
        promptDigest: replayBackendPromptSHA256,
        playerID: playerID
    )
    return AssignmentReplayStartingFixture(
        prompt: BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: configuration.promptIdentity.gameID,
                ownerID: playerID,
                questionVersion: configuration.expectedPromptVersion,
                rawQuestion: raw,
                sessionAttemptID: UUID(),
                connectionID: UUID()
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        ),
        projection: BoardProjectionBuilder.makeProjection(from: envelope.game),
        configuration: configuration
    )
}

@MainActor
private func replayNextFixture(
    checkpoint: ProductionAssignmentReplayCheckpoint
) throws -> (
    prompt: BasicChoicePromptPresentation,
    projection: BoardProjection
) {
    let continuation: AssignmentContinuationFixture = switch checkpoint {
    case .damageFirstThenRemainingHorror: .remainingHorror
    case .horrorFirstThenRemainingDamage: .remainingDamage
    }
    let raw = try DamageAssignmentFixtures.continuationValue(continuation)
    let initial = try AppModelLiveGameTests().damageAssignmentEnvelope(
        rawQuestion: raw,
        scenarioSteps: DamageAssignmentFixtures.continuationQuestionVersion
    )
    let envelope = try replayEnvelope(
        initial,
        assignment: checkpoint.assignmentAfter
    )
    let playerID = try #require(envelope.playerID)
    let payload = try DamageAssignmentFixtures.payload(raw)
    return (
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: playerID,
                questionVersion:
                DamageAssignmentFixtures.continuationQuestionVersion,
                rawQuestion: raw,
                sessionAttemptID: UUID(),
                connectionID: UUID()
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        ),
        BoardProjectionBuilder.makeProjection(from: envelope.game)
    )
}

private func replayEnvelope(
    _ envelope: GetGameEnvelope,
    assignment: AssignmentReplayFields
) throws -> GetGameEnvelope {
    var value = try ContractJSON.decode(
        JSONValue.self,
        from: ContractJSON.encode(envelope.game)
    )
    guard case var .object(root) = value,
          case var .object(investigators)? = root["investigators"],
          case var .object(investigator)? = investigators[
              DamageAssignmentFixtures.investigatorID.codingKey.stringValue
          ]
    else {
        throw TestFailure()
    }
    investigator["assignedHealthDamage"] =
        .number(.integer(Int64(assignment.assignedHealthDamage)))
    investigator["assignedSanityDamage"] =
        .number(.integer(Int64(assignment.assignedSanityDamage)))
    investigators[
        DamageAssignmentFixtures.investigatorID.codingKey.stringValue
    ] = .object(investigator)
    root["investigators"] = .object(investigators)
    value = .object(root)
    return try GetGameEnvelope(
        playerID: envelope.playerID,
        multiplayerMode: envelope.multiplayerMode,
        game: ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        ),
        eventID: envelope.eventID
    )
}

@MainActor
private func replayImportedGame(
    gameID: GameID,
    playerID: PlayerID
) throws -> GetGameEnvelope {
    let envelope = try AppModelLiveGameTests().damageAssignmentEnvelope()
    var value = try ContractJSON.decode(
        JSONValue.self,
        from: ContractJSON.encode(envelope.game)
    )
    guard case var .object(root) = value else {
        throw TestFailure()
    }
    root["id"] = .string(gameID.codingKey.stringValue)
    root["git"] = .string(replayGameRevision)
    value = .object(root)
    return try GetGameEnvelope(
        playerID: playerID,
        multiplayerMode: envelope.multiplayerMode,
        game: ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        ),
        eventID: envelope.eventID
    )
}

private func replayAttestationURL(
    _ request: AssignmentReplayAttestationRequest
) throws -> URL {
    try GameLifecycleService.gameURL(
        request.gameID,
        suffix: "/replay-attestation",
        on: request.serverProfile,
        pin: .current
    )
}

private func jsonResponse(url: URL) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
}
