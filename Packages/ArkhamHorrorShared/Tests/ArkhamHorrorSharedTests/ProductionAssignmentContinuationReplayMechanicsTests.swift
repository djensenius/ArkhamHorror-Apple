@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length

private let replayAppleRevision = String(repeating: "a", count: 40)
private let replayCatalogRevision = "1." + String(repeating: "b", count: 32)
private let replayGameRevision = String(repeating: "c", count: 40)
private let replayServerTree = String(repeating: "1", count: 40)
private let replayServerSourceSHA256 = String(repeating: "2", count: 64)
private let replayCheckpointArtifactSHA256 = String(repeating: "d", count: 64)
private let replayCheckpointEnvelopeSHA256 = String(repeating: "e", count: 64)
private let replayCheckpointName = "enemy-attack-assignment-continuation"

@Suite("Production assignment replay configuration")
struct AssignmentReplayConfigurationTests {
    @Test("No replay environment leaves normal CI disabled")
    func absentConfigurationIsDisabled() throws {
        #expect(try ProductionAssignmentReplayInvocation.parse(environment: [:]) == nil)
    }

    @Test("Complete configuration parses and malformed or unknown values fail closed")
    // swiftlint:disable:next function_body_length
    func strictConfigurationParsing() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let environment = try productionAssignmentReplayEnvironment(
            resultURL: scratch.result
        )
        let invocation = try #require(
            try ProductionAssignmentReplayInvocation.parse(
                environment: environment
            )
        )
        #expect(invocation.configuration.checkpoint
            == .damageFirstThenRemainingHorror)
        #expect(invocation.configuration.serverProfile.endpointSummary
            == "http://127.0.0.1:3002")
        #expect(invocation.configuration.promptIdentity.enemyID
            == DamageAssignmentFixtures.enemyID)
        #expect(invocation.configuration.expectedContractRevision
            == ContractPin.current.supportedSchemaRevision)
        #expect(invocation.configuration.checkpointArtifact.questionVersion == 6)
        let expectedPromptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        #expect(invocation.configuration.checkpointArtifact.promptSHA256
            == expectedPromptDigest)
        #expect(invocation.resultURL == scratch.result)

        var remappedPlayer = environment
        remappedPlayer[ProductionAssignmentReplayEnvironmentKey.playerID] =
            BoardTestFixtures.playerID("000000000002").codingKey.stringValue
        let remappedInvocation = try #require(
            try ProductionAssignmentReplayInvocation.parse(
                environment: remappedPlayer
            )
        )
        #expect(remappedInvocation.configuration.promptIdentity.ownerID
            != remappedInvocation.configuration.checkpointArtifact.playerID)

        var missingToken = environment
        missingToken.removeValue(
            forKey: ProductionAssignmentReplayEnvironmentKey.authToken
        )
        expectConfigurationError(
            .missingEnvironmentKey(
                ProductionAssignmentReplayEnvironmentKey.authToken
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: missingToken
            )
        }

        var unsafeToken = environment
        unsafeToken[ProductionAssignmentReplayEnvironmentKey.authToken] =
            "secret\nvalue"
        expectConfigurationError(
            .invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.authToken
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: unsafeToken
            )
        }

        var unknown = environment
        unknown[ProductionAssignmentReplayEnvironmentKey.prefix + "TYPO"] = "1"
        expectConfigurationError(
            .unknownEnvironmentKey(
                ProductionAssignmentReplayEnvironmentKey.prefix + "TYPO"
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: unknown
            )
        }

        var callerClaimedServerBuild = environment
        let removedBackendKey =
            ProductionAssignmentReplayEnvironmentKey.prefix +
            "EXPECTED_BACKEND_REVISION"
        callerClaimedServerBuild[removedBackendKey] =
            ContractPin.current.backendCommit
        expectConfigurationError(.unknownEnvironmentKey(removedBackendKey)) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: callerClaimedServerBuild
            )
        }

        var wrongContract = environment
        wrongContract[
            ProductionAssignmentReplayEnvironmentKey.expectedContractRevision
        ] = "0.0.0"
        expectConfigurationError(.contractRevisionMismatch) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: wrongContract
            )
        }

        var spoofedChildRevision = environment
        spoofedChildRevision[
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
        ] = replayAppleRevision
        expectConfigurationError(
            .forbiddenEnvironmentKey(
                ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: spoofedChildRevision
            )
        }

        var spoofedCheckpointIdentity = environment
        spoofedCheckpointIdentity[
            ProductionAssignmentReplayEnvironmentKey
                .observedCheckpointArtifactSHA256
        ] = String(repeating: "f", count: 64)
        expectConfigurationError(
            .forbiddenEnvironmentKey(
                ProductionAssignmentReplayEnvironmentKey
                    .observedCheckpointArtifactSHA256
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: spoofedCheckpointIdentity
            )
        }

        let malformedURL = scratch.directory.appendingPathComponent(
            "malformed-checkpoint.json"
        )
        try writeProductionAssignmentReplayCheckpoint(
            to: malformedURL,
            promptDigest: String(repeating: "A", count: 64)
        )
        var malformedCheckpoint = environment
        malformedCheckpoint[
            ProductionAssignmentReplayEnvironmentKey.checkpointArtifactPath
        ] = malformedURL.path
        expectConfigurationError(.invalidCheckpointArtifact) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: malformedCheckpoint
            )
        }
    }

    @Test("Child checkpoint and observed Apple revision must match the parent")
    func childConfigurationIdentity() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        var environment = try productionAssignmentReplayEnvironment(
            resultURL: scratch.result
        )
        let parent = try #require(
            try ProductionAssignmentReplayInvocation.parse(
                environment: environment
            )
        )
        environment[
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
        ] = replayAppleRevision
        environment[
            ProductionAssignmentReplayEnvironmentKey
                .observedCheckpointArtifactSHA256
        ] = parent.configuration.checkpointArtifact.artifactSHA256
        let configuration = try ProductionAssignmentReplayConfiguration.child(
            environment: environment,
            checkpoint: .damageFirstThenRemainingHorror
        )
        #expect(configuration.expectedAppleRevision == replayAppleRevision)

        expectConfigurationError(.checkpointMismatch) {
            _ = try ProductionAssignmentReplayConfiguration.child(
                environment: environment,
                checkpoint: .horrorFirstThenRemainingDamage
            )
        }

        environment[
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
        ] = String(repeating: "c", count: 40)
        expectConfigurationError(.appleRevisionMismatch) {
            _ = try ProductionAssignmentReplayConfiguration.child(
                environment: environment,
                checkpoint: .damageFirstThenRemainingHorror
            )
        }
    }

    @Test("Child rejects a checkpoint substituted after parent validation")
    func childRejectsCheckpointSubstitution() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        var environment = try productionAssignmentReplayEnvironment(
            resultURL: scratch.result
        )
        let parent = try #require(
            try ProductionAssignmentReplayInvocation.parse(
                environment: environment
            )
        )
        environment[
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
        ] = replayAppleRevision
        environment[
            ProductionAssignmentReplayEnvironmentKey
                .observedCheckpointArtifactSHA256
        ] = parent.configuration.checkpointArtifact.artifactSHA256
        let checkpointURL = try URL(fileURLWithPath: #require(
            environment[
                ProductionAssignmentReplayEnvironmentKey.checkpointArtifactPath
            ]
        ))
        try writeProductionAssignmentReplayCheckpoint(
            to: checkpointURL,
            envelopeDigest: String(repeating: "f", count: 64)
        )
        expectConfigurationError(.checkpointArtifactIdentityMismatch) {
            _ = try ProductionAssignmentReplayConfiguration.child(
                environment: environment,
                checkpoint: .damageFirstThenRemainingHorror
            )
        }
    }
}

@Suite("Production assignment replay checkpoint artifact")
struct AssignmentReplayCheckpointArtifactTests {
    @Test("Exact file bytes and embedded envelope identity are digest-bound")
    func exactArtifactDigest() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let checkpointURL = scratch.directory.appendingPathComponent(
            "checkpoint.json"
        )
        try writeProductionAssignmentReplayCheckpoint(to: checkpointURL)
        let bytes = try Data(contentsOf: checkpointURL)
        let artifact =
            try AssignmentReplayCheckpointArtifact.load(
                from: checkpointURL
            )
        let expectedArtifactDigest =
            LocaleCatalogLoader.sha256Hex(bytes)
        #expect(artifact.artifactSHA256 == expectedArtifactDigest)
        #expect(artifact.envelopeSHA256 == replayCheckpointEnvelopeSHA256)
        #expect(artifact.checkpointName == replayCheckpointName)
        #expect(artifact.questionVersion == 6)
        #expect(artifact.playerID
            == BoardTestFixtures.playerID("000000000001"))
        #expect(artifact.sourceGameRevision == replayGameRevision)

        var changedBytes = bytes
        changedBytes.append(0x0A)
        try changedBytes.write(to: checkpointURL)
        let changed =
            try AssignmentReplayCheckpointArtifact.load(
                from: checkpointURL
            )
        #expect(changed.artifactSHA256 != artifact.artifactSHA256)
        #expect(changed.envelopeSHA256 == artifact.envelopeSHA256)
    }

    @Test("Symlinks and duplicate-key checkpoint documents fail closed")
    func unsafeOrAmbiguousArtifact() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let checkpointURL = scratch.directory.appendingPathComponent(
            "checkpoint.json"
        )
        try writeProductionAssignmentReplayCheckpoint(to: checkpointURL)
        let linkURL = scratch.directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: checkpointURL
        )
        #expect(
            throws: ProductionAssignmentReplayError.invalidCheckpointArtifact
        ) {
            _ = try AssignmentReplayCheckpointArtifact.load(
                from: linkURL
            )
        }

        let duplicateURL = scratch.directory.appendingPathComponent(
            "duplicate.json"
        )
        try Data(
            #"{"replayCheckpoint":null,"replayCheckpoint":null}"#.utf8
        ).write(to: duplicateURL)
        #expect(
            throws: ProductionAssignmentReplayError.invalidCheckpointArtifact
        ) {
            _ = try AssignmentReplayCheckpointArtifact.load(
                from: duplicateURL
            )
        }
    }
}

@Suite("Production assignment replay cases")
struct AssignmentReplayCheckpointTests {
    @Test("Both checkpoints preserve their authoritative source order and deltas")
    func checkpointSelection() throws {
        let damageFirst =
            ProductionAssignmentReplayCheckpoint.damageFirstThenRemainingHorror
        #expect(damageFirst.sourceIndex == 0)
        #expect(damageFirst.selectedAssignmentKind == .damage)
        #expect(damageFirst.nextAssignmentKind == .horror)
        #expect(damageFirst.assignmentAfter == AssignmentReplayFields(
            assignedHealthDamage: 1,
            assignedSanityDamage: 0
        ))

        let horrorFirst =
            ProductionAssignmentReplayCheckpoint.horrorFirstThenRemainingDamage
        #expect(horrorFirst.sourceIndex == 1)
        #expect(horrorFirst.selectedAssignmentKind == .horror)
        #expect(horrorFirst.nextAssignmentKind == .damage)
        #expect(horrorFirst.assignmentAfter == AssignmentReplayFields(
            assignedHealthDamage: 0,
            assignedSanityDamage: 1
        ))

        let victim = try AssignmentContinuationReplayDriver.victim()
        #expect(victim.discoveredIdentifier
            == "ArkhamHorrorSharedTests." +
            "AssignmentContinuationReplayVictimSuite/" +
            "productionAssignmentContinuationReplayVictim()")
        let regex = try NSRegularExpression(pattern: victim.exactFilter)
        #expect(regex.firstMatch(
            in: victim.discoveredIdentifier + "/case",
            range: NSRange(
                (victim.discoveredIdentifier + "/case").startIndex...,
                in: victim.discoveredIdentifier + "/case"
            )
        ) != nil)
    }

    @MainActor
    @Test(
        "Both cases validate their combined prompt, continuation, and authoritative delta",
        arguments: ProductionAssignmentReplayCheckpoint.allCases
    )
    func checkpointPromptValidation(
        _ checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws {
        let starting = try productionAssignmentStartingFixture(
            checkpoint: checkpoint
        )
        let startingObservation =
            try ProductionAssignmentReplayValidator.validateStartingPrompt(
                starting.prompt,
                projection: starting.projection,
                configuration: starting.configuration
            )
        #expect(startingObservation.assignmentBefore == checkpoint.assignmentBefore)

        let next = try productionAssignmentNextFixture(checkpoint: checkpoint)
        let nextObservation =
            try ProductionAssignmentReplayValidator.validateNextPrompt(
                next.prompt,
                projection: next.projection,
                configuration: starting.configuration
            )
        #expect(nextObservation.assignmentAfter == checkpoint.assignmentAfter)
        #expect(
            try ProductionAssignmentReplayValidator.validateAssignmentDelta(
                before: startingObservation.assignmentBefore,
                after: nextObservation.assignmentAfter,
                checkpoint: checkpoint
            ) == checkpoint.assignmentDelta
        )
    }

    @MainActor
    @Test("Retryable fast reconciliation requires exact send and next-state proofs")
    func retryableResolutionProofs() throws {
        let starting = try productionAssignmentStartingFixture()
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
        let nextFixture = try productionAssignmentNextFixture(
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
            throws: ProductionAssignmentReplayError.sentAnswerCountMismatch
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
}

@Suite("Production assignment replay evidence")
struct ProductionAssignmentReplayEvidenceTests {
    @Test("Evidence encoding is canonical, digest-bound, and tamper evident")
    // swiftlint:disable:next function_body_length
    func deterministicEncodingAndDigest() throws {
        let evidence = try productionAssignmentReplayEvidence()
        let artifact = try AssignmentReplayEvidenceArtifact(
            evidence: evidence
        )
        let first = try artifact.validatedData()
        let second = try artifact.validatedData()
        #expect(first == second)
        let evidenceDigest =
            try ProductionAssignmentReplayCanonicalJSON.digest(evidence)
        #expect(artifact.evidenceCanonicalSHA256 == evidenceDigest)
        let decoded =
            try AssignmentReplayEvidenceArtifact.decodeAndValidate(first)
        #expect(decoded == artifact)
        #expect(decoded.evidence.checkpoint.artifactSHA256
            == replayCheckpointArtifactSHA256)
        #expect(decoded.evidence.checkpoint.envelopeSHA256
            == replayCheckpointEnvelopeSHA256)
        #expect(decoded.evidence.revisions.serverBuild.gitRevision
            == ContractPin.current.backendCommit)
        #expect(decoded.evidence.revisions.game == replayGameRevision)

        var unknownFieldValue = try ContractJSON.decode(
            JSONValue.self,
            from: first
        )
        guard case var .object(unknownFieldRoot) = unknownFieldValue else {
            throw TestFailure()
        }
        unknownFieldRoot["unknown"] = .bool(true)
        unknownFieldValue = .object(unknownFieldRoot)
        let unknownFieldData = try LosslessJSONSerializer.serialize(
            unknownFieldValue
        )
        #expect(
            throws: ProductionAssignmentReplayEvidenceError
                .nonCanonicalEncoding
        ) {
            _ = try AssignmentReplayEvidenceArtifact
                .decodeAndValidate(unknownFieldData)
        }

        var trailingNewline = first
        trailingNewline.append(0x0A)
        #expect(
            throws: ProductionAssignmentReplayEvidenceError
                .nonCanonicalEncoding
        ) {
            _ = try AssignmentReplayEvidenceArtifact
                .decodeAndValidate(trailingNewline)
        }

        var value = try ContractJSON.decode(JSONValue.self, from: first)
        guard case var .object(root) = value else { throw TestFailure() }
        root["evidenceCanonicalSHA256"] =
            .string(String(repeating: "0", count: 64))
        value = .object(root)
        let tampered = try LosslessJSONSerializer.serialize(value)
        let tamperedArtifact = try ContractJSON.decode(
            AssignmentReplayEvidenceArtifact.self,
            from: tampered
        )
        #expect(throws: ProductionAssignmentReplayEvidenceError.digestMismatch) {
            _ = try tamperedArtifact.validatedData()
        }
    }
}

@MainActor
@Suite("Production assignment replay identity validation")
struct ProductionAssignmentReplayIdentityTests {
    @Test("Stale version, wrong digest, and wrong semantic source fail closed")
    func staleAndWrongStartingIdentity() throws {
        let fixture = try productionAssignmentStartingFixture()
        _ = try ProductionAssignmentReplayValidator.validateStartingPrompt(
            fixture.prompt,
            projection: fixture.projection,
            configuration: fixture.configuration
        )

        let stale = try productionAssignmentReplayConfiguration(
            promptDigest: fixture.configuration.expectedPromptDigest,
            promptVersion: fixture.configuration.expectedPromptVersion + 1
        )
        #expect(throws: ProductionAssignmentReplayError.startingPromptVersionMismatch) {
            _ = try ProductionAssignmentReplayValidator.validateStartingPrompt(
                fixture.prompt,
                projection: fixture.projection,
                configuration: stale
            )
        }

        let wrongDigest = try productionAssignmentReplayConfiguration(
            promptDigest: String(repeating: "d", count: 64)
        )
        #expect(throws: ProductionAssignmentReplayError.startingPromptDigestMismatch) {
            _ = try ProductionAssignmentReplayValidator.validateStartingPrompt(
                fixture.prompt,
                projection: fixture.projection,
                configuration: wrongDigest
            )
        }

        let wrongSource = try productionAssignmentReplayConfiguration(
            promptDigest: fixture.configuration.expectedPromptDigest,
            enemyID: BoardTestFixtures.enemyID("000000000389")
        )
        #expect(throws: ProductionAssignmentReplayError.startingPromptShapeMismatch) {
            _ = try ProductionAssignmentReplayValidator.validateStartingPrompt(
                fixture.prompt,
                projection: fixture.projection,
                configuration: wrongSource
            )
        }
    }

    @Test("Game revision, game, and authenticated player identity fail closed")
    // swiftlint:disable:next function_body_length
    func authoritativeIdentity() throws {
        let fixture = try productionAssignmentStartingFixture()
        let configuration = fixture.configuration
        let attestation = productionAssignmentReplayAttestation(
            configuration: configuration
        )
        let valid = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: configuration.promptIdentity.gameID,
            gameRevision: configuration.checkpointArtifact.sourceGameRevision,
            playerID: configuration.promptIdentity.ownerID,
            projection: fixture.projection
        )
        try AssignmentReplayAuthoritativeValidator.validate(
            valid,
            projection: fixture.projection,
            configuration: configuration,
            attestation: attestation,
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
                attestation: attestation,
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
                attestation: attestation,
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
                attestation: attestation,
                requiresPlayerIdentity: true
            )
        }
    }
}

@Suite("Production assignment replay server attestation")
struct AssignmentReplayAttestationTests {
    @Test("Authenticated game-bound attestation is required and validated")
    func validAttestation() async throws {
        let promptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        let configuration = try productionAssignmentReplayConfiguration(
            promptDigest: promptDigest,
            playerID: BoardTestFixtures.playerID("000000000002"),
            checkpointPlayerID:
            BoardTestFixtures.playerID("000000000001")
        )
        let expected = productionAssignmentReplayAttestation(
            configuration: configuration
        )
        let url = try GameLifecycleService.gameURL(
            configuration.promptIdentity.gameID,
            suffix: "/replay-attestation",
            on: configuration.serverProfile,
            pin: .current
        )
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(expected),
            response: response
        )
        let actual =
            try await AssignmentReplayAttestationClient(
                transport: transport
            ).fetch(configuration: configuration)
        #expect(actual == expected)
        let request = try #require(await transport.capturedRequest)
        #expect(request.url == url)
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == "Token unit-test-token")
    }

    @Test("Missing and malformed authority fail closed")
    func unavailableOrMalformedAttestation() async throws {
        let promptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        let configuration = try productionAssignmentReplayConfiguration(
            promptDigest: promptDigest
        )
        let url = try GameLifecycleService.gameURL(
            configuration.promptIdentity.gameID,
            suffix: "/replay-attestation",
            on: configuration.serverProfile,
            pin: .current
        )
        let unavailableResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let unavailable = GameLifecycleRecordingTransport(
            data: Data("{}".utf8),
            response: unavailableResponse
        )
        await #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationUnavailable
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: unavailable
            ).fetch(configuration: configuration)
        }

        let malformedResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let malformed = GameLifecycleRecordingTransport(
            data: Data(#"{"schemaVersion":1}"#.utf8),
            response: malformedResponse
        )
        await #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMalformed
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: malformed
            ).fetch(configuration: configuration)
        }
    }

    @Test("Caller-spoofed or dirty server authority fails closed")
    func spoofedAttestation() throws {
        let promptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        let configuration = try productionAssignmentReplayConfiguration(
            promptDigest: promptDigest
        )
        let spoofed = productionAssignmentReplayAttestation(
            configuration: configuration,
            serverBuild: productionAssignmentReplayServerBuild(
                gitRevision: String(repeating: "f", count: 40)
            )
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try spoofed.validate(configuration: configuration)
        }
        let dirtyBuild = productionAssignmentReplayAttestation(
            configuration: configuration,
            serverBuild: productionAssignmentReplayServerBuild(
                sourceClean: false,
                attestation: "unattested"
            )
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try dirtyBuild.validate(configuration: configuration)
        }
    }

    @Test("Attestation rejects unknown fields")
    func unknownAttestationField() async throws {
        let promptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        let configuration = try productionAssignmentReplayConfiguration(
            promptDigest: promptDigest
        )
        let expected = productionAssignmentReplayAttestation(
            configuration: configuration
        )
        let url = try GameLifecycleService.gameURL(
            configuration.promptIdentity.gameID,
            suffix: "/replay-attestation",
            on: configuration.serverProfile,
            pin: .current
        )
        let jsonResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        var value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(expected)
        )
        guard case var .object(root) = value else {
            throw TestFailure()
        }
        root["callerProof"] = .string("untrusted")
        value = .object(root)
        let unknownField = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(value),
            response: jsonResponse
        )
        await #expect(
            throws: ProductionAssignmentReplayError.serverAttestationMalformed
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: unknownField
            ).fetch(configuration: configuration)
        }
    }

    @Test("Attestation rejects misleading media types")
    func misleadingAttestationMediaType() async throws {
        let promptDigest =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                DamageAssignmentFixtures.value()
            )
        let configuration = try productionAssignmentReplayConfiguration(
            promptDigest: promptDigest
        )
        let expected = productionAssignmentReplayAttestation(
            configuration: configuration
        )
        let url = try GameLifecycleService.gameURL(
            configuration.promptIdentity.gameID,
            suffix: "/replay-attestation",
            on: configuration.serverProfile,
            pin: .current
        )
        let misleadingResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/jsonp"]
        ))
        let misleadingMediaType = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(expected),
            response: misleadingResponse
        )
        await #expect(
            throws: ProductionAssignmentReplayError.serverAttestationMalformed
        ) {
            _ = try await AssignmentReplayAttestationClient(
                transport: misleadingMediaType
            ).fetch(configuration: configuration)
        }
    }
}

@MainActor
@Suite("Production assignment replay driver wiring")
struct AssignmentReplayDriverWiringTests {
    @Test("Concrete driver stages the exact victim and validated child environment")
    // swiftlint:disable:next function_body_length
    func driverWiring() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let environment = try productionAssignmentReplayEnvironment(
            resultURL: scratch.result,
            checkpoint: .horrorFirstThenRemainingDamage
        )
        let invocation = try #require(
            try ProductionAssignmentReplayInvocation.parse(
                environment: environment
            )
        )
        let artifactData = try AssignmentReplayEvidenceArtifact(
            evidence: productionAssignmentReplayEvidence(
                checkpoint: .horrorFirstThenRemainingDamage,
                checkpointArtifact:
                invocation.configuration.checkpointArtifact
            )
        ).validatedData()
        let expectedFilter =
            try AssignmentContinuationReplayDriver.victim().exactFilter
        var launched = false
        let result = try AssignmentContinuationReplayDriver.run(
            invocation: invocation,
            hostArguments: ["/test-host", "--filter", "old"],
            appleRevisionProvider: { replayAppleRevision },
            deadlineRunner: { filter, childEnvironment, deadline, _ in
                launched = true
                #expect(filter == expectedFilter)
                #expect(deadline == 30)
                #expect(childEnvironment[ProductionReplayEnvironmentKey.checkpoint]
                    == ProductionAssignmentReplayCheckpoint
                    .horrorFirstThenRemainingDamage.rawValue)
                #expect(childEnvironment[
                    ProductionAssignmentReplayEnvironmentKey.checkpoint
                ] == ProductionAssignmentReplayCheckpoint
                    .horrorFirstThenRemainingDamage.rawValue)
                #expect(childEnvironment[
                    ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
                ] == replayAppleRevision)
                #expect(childEnvironment[
                    ProductionAssignmentReplayEnvironmentKey
                        .observedCheckpointArtifactSHA256
                ] == invocation.configuration.checkpointArtifact.artifactSHA256)
                #expect(childEnvironment[
                    ProductionAssignmentReplayEnvironmentKey.authToken
                ] == "unit-test-token")
                #expect(childEnvironment[
                    ProductionAssignmentReplayEnvironmentKey.resultPath
                ] == scratch.result.path)
                let staging = try URL(fileURLWithPath: #require(
                    childEnvironment[ProductionReplayEnvironmentKey.resultPath]
                ))
                try artifactData.write(to: staging)
                return .completed
            }
        )
        #expect(launched)
        #expect(result.outcome == .completed)
        let resultData = try result.resultData()
        #expect(resultData == artifactData)

        let wrongIdentityData = try AssignmentReplayEvidenceArtifact(
            evidence: productionAssignmentReplayEvidence(
                checkpoint: .horrorFirstThenRemainingDamage,
                gameID: BoardTestFixtures.gameID("000000000901"),
                checkpointArtifact:
                invocation.configuration.checkpointArtifact
            )
        ).validatedData()
        #expect(
            throws: ProductionAssignmentReplayEvidenceError
                .configurationMismatch
        ) {
            _ = try AssignmentContinuationReplayDriver.run(
                invocation: invocation,
                appleRevisionProvider: { replayAppleRevision },
                deadlineRunner: { _, childEnvironment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        childEnvironment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    try wrongIdentityData.write(to: staging)
                    return .completed
                }
            )
        }

        launched = false
        #expect(throws: AssignmentReplayConfigurationError.appleRevisionMismatch) {
            _ = try AssignmentContinuationReplayDriver.run(
                invocation: invocation,
                appleRevisionProvider: { String(repeating: "c", count: 40) },
                deadlineRunner: { _, _, _, _ in
                    launched = true
                    return .completed
                }
            )
        }
        #expect(!launched)
    }

    @Test("Socket observation delegates to the real connection seam and records successes")
    func recordingSocketWiring() async throws {
        let baseFactory = FakeGameSocketFactory()
        let baseConnection = FakeGameSocketConnection()
        await baseConnection.enqueueSendResult(.success(()))
        await baseFactory.enqueueConnectResult(.success(baseConnection))
        let recorder = ProductionAssignmentReplaySocketRecorder()
        let authoritativeRecorder =
            AssignmentReplayAuthoritativeRecorder()
        let factory = AssignmentReplayRecordingSocketFactory(
            base: baseFactory,
            recorder: recorder,
            authoritativeRecorder: authoritativeRecorder
        )
        let connection = try await factory.connect(
            to: #require(URL(string: "wss://example.com/game"))
        )
        let envelope = try AppModelLiveGameTests().damageAssignmentEnvelope()
        let update = BoardSnapshotUpdate.snapshot(envelope.game)
        let updateData = try ContractJSON.encode(update)
        await baseConnection.enqueue(.event(.message(updateData)))
        #expect(try await connection.nextEvent() == .message(updateData))
        let observation = await authoritativeRecorder.latest(
            gameID: envelope.game.id,
            questionVersion: envelope.game.scenarioSteps,
            source: .socket
        )
        #expect(observation?.gameRevision == envelope.game.git)
        #expect(observation?.playerID == nil)

        let answer = Data(#"{"tag":"Answer"}"#.utf8)
        try await connection.send(answer)
        #expect(await baseConnection.sentData == [answer])
        #expect(recorder.snapshot() == [answer])

        await baseConnection.enqueueSendResult(
            .failure(GameSocketTransportError())
        )
        do {
            try await connection.send(Data("failed".utf8))
            Issue.record("Expected the delegated send failure.")
        } catch is GameSocketTransportError {
            #expect(recorder.snapshot() == [answer])
        }
    }

    @Test("REST observation delegates to the production HTTP seam")
    func recordingRESTWiring() async throws {
        let envelope = try AppModelLiveGameTests().damageAssignmentEnvelope()
        let data = try ContractJSON.encode(envelope)
        let url = try #require(URL(string: "https://example.com/api/v1/arkham/games/id"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let base = GameLifecycleRecordingTransport(
            data: data,
            response: response
        )
        let recorder = AssignmentReplayAuthoritativeRecorder()
        let transport = AssignmentReplayRecordingGameTransport(
            base: base,
            recorder: recorder
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let observedResponse = try await transport.data(for: request)
        #expect(observedResponse.0 == data)
        #expect(await base.capturedRequest == request)

        let observation = await recorder.latest(
            gameID: envelope.game.id,
            questionVersion: envelope.game.scenarioSteps,
            source: .rest
        )
        #expect(observation?.gameRevision == envelope.game.git)
        #expect(observation?.playerID == envelope.playerID)
    }
}

private func productionAssignmentReplayEnvironment(
    resultURL: URL,
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror
) throws -> [String: String] {
    let checkpointURL = resultURL.deletingLastPathComponent()
        .appendingPathComponent(
            "checkpoint-\(UUID().uuidString).json"
        )
    try writeProductionAssignmentReplayCheckpoint(
        to: checkpointURL
    )
    return [
        ProductionAssignmentReplayEnvironmentKey.checkpoint: checkpoint.rawValue,
        ProductionAssignmentReplayEnvironmentKey.resultPath: resultURL.path,
        ProductionAssignmentReplayEnvironmentKey.deadlineSeconds: "30",
        ProductionAssignmentReplayEnvironmentKey.serverBaseURL:
            "http://127.0.0.1:3002",
        ProductionAssignmentReplayEnvironmentKey.serverProfileID:
            "00000000-0000-0000-0000-000000000777",
        ProductionAssignmentReplayEnvironmentKey.authToken: "unit-test-token",
        ProductionAssignmentReplayEnvironmentKey.gameID:
            BoardTestFixtures.gameID().codingKey.stringValue,
        ProductionAssignmentReplayEnvironmentKey.playerID:
            BoardTestFixtures.playerID("000000000001").codingKey.stringValue,
        ProductionAssignmentReplayEnvironmentKey.expectedAppleRevision:
            replayAppleRevision,
        ProductionAssignmentReplayEnvironmentKey.expectedContractRevision:
            ContractPin.current.supportedSchemaRevision.description,
        ProductionAssignmentReplayEnvironmentKey.expectedCatalogRevision:
            replayCatalogRevision,
        ProductionAssignmentReplayEnvironmentKey.expectedPromptEnemyID:
            DamageAssignmentFixtures.enemyID.codingKey.stringValue,
        ProductionAssignmentReplayEnvironmentKey.expectedPromptInvestigatorID:
            DamageAssignmentFixtures.investigatorID.codingKey.stringValue,
        ProductionAssignmentReplayEnvironmentKey.checkpointArtifactPath:
            checkpointURL.path,
    ]
}

private struct AssignmentReplayStartingFixture {
    let prompt: BasicChoicePromptPresentation
    let projection: BoardProjection
    let configuration: ProductionAssignmentReplayConfiguration
}

@MainActor
private func productionAssignmentStartingFixture(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror
) throws -> AssignmentReplayStartingFixture {
    let envelope = try AppModelLiveGameTests().damageAssignmentEnvelope()
    let playerID = try #require(envelope.playerID)
    let raw = try DamageAssignmentFixtures.value()
    let payload = try DamageAssignmentFixtures.payload(raw)
    let prompt = BasicChoicePromptPresentation(
        identity: BasicChoicePromptIdentity(
            gameID: BoardTestFixtures.gameID(),
            ownerID: playerID,
            questionVersion: 6,
            rawQuestion: raw,
            sessionAttemptID: UUID(),
            connectionID: UUID()
        ),
        question: payload.state,
        readOnlyReason: nil,
        actionPhase: nil,
        actionChoiceIndex: nil,
        serverFeedback: nil
    )
    let configuration = try productionAssignmentReplayConfiguration(
        checkpoint: checkpoint,
        promptDigest: ProductionAssignmentReplayCanonicalJSON.promptDigest(raw),
        playerID: playerID
    )
    return AssignmentReplayStartingFixture(
        prompt: prompt,
        projection: BoardProjectionBuilder.makeProjection(from: envelope.game),
        configuration: configuration
    )
}

@MainActor
private func productionAssignmentNextFixture(
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
    let envelope = try productionAssignmentEnvelope(
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

private func productionAssignmentEnvelope(
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
    let snapshot = try ContractJSON.decode(
        PublicGameSnapshot.self,
        from: ContractJSON.encode(value)
    )
    return GetGameEnvelope(
        playerID: envelope.playerID,
        multiplayerMode: envelope.multiplayerMode,
        game: snapshot,
        eventID: envelope.eventID
    )
}

private func productionAssignmentReplayConfiguration(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror,
    promptDigest: String,
    promptVersion: Int = 6,
    gameID: GameID = BoardTestFixtures.gameID(),
    playerID: PlayerID = BoardTestFixtures.playerID("000000000001"),
    checkpointPlayerID: PlayerID? = nil,
    enemyID: EnemyID = DamageAssignmentFixtures.enemyID
) throws -> ProductionAssignmentReplayConfiguration {
    let profile = try ServerProfile.custom(
        id: #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000777")
        ),
        displayName: "Production assignment replay",
        rawURL: "http://127.0.0.1:3002"
    )
    let checkpointArtifact =
        productionAssignmentReplayCheckpointArtifact(
            promptDigest: promptDigest,
            promptVersion: promptVersion,
            playerID: checkpointPlayerID ?? playerID
        )
    return try ProductionAssignmentReplayConfiguration(
        checkpoint: checkpoint,
        deadlineSeconds: 30,
        serverProfile: profile,
        authToken: "unit-test-token",
        promptIdentity: ProductionAssignmentReplayPromptIdentity(
            gameID: gameID,
            ownerID: playerID,
            enemyID: enemyID,
            investigatorID: DamageAssignmentFixtures.investigatorID
        ),
        expectedAppleRevision: replayAppleRevision,
        expectedContractRevision: ContractPin.current.supportedSchemaRevision,
        expectedCatalogRevision: replayCatalogRevision,
        checkpointArtifact: checkpointArtifact
    )
}

// swiftlint:disable:next function_body_length
private func productionAssignmentReplayEvidence(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror,
    gameID: GameID = BoardTestFixtures.gameID(),
    checkpointArtifact:
    AssignmentReplayCheckpointArtifact? = nil
) throws -> ProductionAssignmentReplayEvidence {
    let playerID = BoardTestFixtures.playerID("000000000001")
    let startDigest = try ProductionAssignmentReplayCanonicalJSON.promptDigest(
        DamageAssignmentFixtures.value()
    )
    let checkpointArtifact = checkpointArtifact ??
        productionAssignmentReplayCheckpointArtifact(
            promptDigest: startDigest,
            playerID: playerID
        )
    return ProductionAssignmentReplayEvidence(
        schemaVersion: ProductionAssignmentReplayEvidence.currentSchemaVersion,
        checkpoint: AssignmentReplayCheckpointEvidence(
            caseName: checkpoint.rawValue,
            name: checkpointArtifact.checkpointName,
            playerID: checkpointArtifact.playerID,
            questionVersion: checkpointArtifact.questionVersion,
            promptCanonicalSHA256: checkpointArtifact.promptSHA256,
            artifactSHA256: checkpointArtifact.artifactSHA256,
            envelopeSHA256: checkpointArtifact.envelopeSHA256
        ),
        source: ProductionAssignmentReplaySourceEvidence(
            gameID: gameID,
            playerID: playerID,
            promptTag: "QuestionWithSource",
            sourceTag: "EnemyAttackSource",
            enemyID: DamageAssignmentFixtures.enemyID,
            investigatorID: DamageAssignmentFixtures.investigatorID,
            promptVersion: 6,
            promptCanonicalSHA256: startDigest,
            selectedAssignment: checkpoint.selectedAssignmentKind.productionReplayName,
            sourceIndex: checkpoint.sourceIndex
        ),
        answer: BasicChoiceAnswer(
            choice: checkpoint.sourceIndex,
            playerID: playerID,
            questionVersion: 6
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
            promptTag: "QuestionWithSource",
            sourceTag: "EnemyAttackSource",
            assignment: checkpoint.nextAssignmentKind.productionReplayName,
            version: 7,
            canonicalSHA256: String(repeating: "e", count: 64)
        ),
        revisions: AssignmentReplayRevisionEvidence(
            serverBuild: productionAssignmentReplayServerBuild(),
            game: checkpointArtifact.sourceGameRevision,
            apple: replayAppleRevision,
            contract: ContractPin.current.supportedSchemaRevision,
            catalog: replayCatalogRevision
        )
    )
}

private func productionAssignmentReplayCheckpointArtifact(
    promptDigest: String,
    promptVersion: Int = 6,
    playerID: PlayerID = BoardTestFixtures.playerID("000000000001")
) -> AssignmentReplayCheckpointArtifact {
    AssignmentReplayCheckpointArtifact(
        fileURL: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("assignment-replay-checkpoint.json"),
        artifactSHA256: replayCheckpointArtifactSHA256,
        envelopeSHA256: replayCheckpointEnvelopeSHA256,
        checkpointName: replayCheckpointName,
        questionVersion: promptVersion,
        playerID: playerID,
        promptTag: BasicChoiceQuestionKind.questionWithSource.rawValue,
        promptSHA256: promptDigest,
        contractRevision:
        ContractPin.current.supportedSchemaRevision.description,
        sourceGameRevision: replayGameRevision
    )
}

private func productionAssignmentReplayAttestation(
    configuration: ProductionAssignmentReplayConfiguration,
    serverBuild: AssignmentReplayServerBuildIdentity =
        productionAssignmentReplayServerBuild()
) -> ProductionAssignmentReplayAttestation {
    ProductionAssignmentReplayAttestation(
        schemaVersion: ProductionAssignmentReplayAttestation.schemaVersion,
        gameID: configuration.promptIdentity.gameID,
        playerID: configuration.promptIdentity.ownerID,
        checkpointPlayerID: configuration.checkpointArtifact.playerID,
        serverBuild: serverBuild,
        gameRevision: configuration.checkpointArtifact.sourceGameRevision,
        checkpointArtifactSHA256:
        configuration.checkpointArtifact.artifactSHA256,
        checkpointEnvelopeSHA256:
        configuration.checkpointArtifact.envelopeSHA256,
        contractRevision:
        configuration.expectedContractRevision.description,
        checkpointName: configuration.checkpointArtifact.checkpointName
    )
}

private func productionAssignmentReplayServerBuild(
    gitRevision: String = ContractPin.current.backendCommit,
    sourceClean: Bool = true,
    attestation: String = "git-clean"
) -> AssignmentReplayServerBuildIdentity {
    AssignmentReplayServerBuildIdentity(
        gitRevision: gitRevision,
        gitTree: replayServerTree,
        sourceSHA256: replayServerSourceSHA256,
        sourceClean: sourceClean,
        attestation: attestation
    )
}

private func writeProductionAssignmentReplayCheckpoint(
    to url: URL,
    promptDigest: String? = nil,
    promptVersion: Int = 6,
    envelopeDigest: String = replayCheckpointEnvelopeSHA256
) throws {
    let promptDigest = try promptDigest ??
        ProductionAssignmentReplayCanonicalJSON.promptDigest(
            DamageAssignmentFixtures.value()
        )
    let playerID =
        BoardTestFixtures.playerID("000000000001").codingKey.stringValue
    let value = JSONValue.object([
        "replayCheckpoint": .object([
            "type": .string("arkham-replay-checkpoint"),
            "provenance": .object([
                "schemaVersion": .number(.integer(1)),
                "contractSchemaRevision": .string(
                    ContractPin.current.supportedSchemaRevision.description
                ),
                "sourceGameGitRevision": .string(replayGameRevision),
                "checkpoint": .object([
                    "type": .string("question"),
                    "name": .string(replayCheckpointName),
                    "questionVersion": .number(
                        .integer(Int64(promptVersion))
                    ),
                    "playerId": .string(playerID),
                    "promptTag": .string(
                        BasicChoiceQuestionKind.questionWithSource.rawValue
                    ),
                    "promptSha256": .string(promptDigest),
                ]),
            ]),
            "envelopeSha256": .string(envelopeDigest),
        ]),
    ])
    try LosslessJSONSerializer.serialize(value).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func expectConfigurationError(
    _ expected: AssignmentReplayConfigurationError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected replay configuration to fail closed.")
    } catch let error as AssignmentReplayConfigurationError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected a typed replay configuration error.")
    }
}
