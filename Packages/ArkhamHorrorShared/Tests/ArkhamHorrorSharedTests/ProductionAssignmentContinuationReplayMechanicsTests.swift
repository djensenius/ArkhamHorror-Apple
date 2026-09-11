@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length

private let replayAppleRevision = String(repeating: "a", count: 40)
private let replayCatalogRevision = "1." + String(repeating: "b", count: 32)

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
        #expect(invocation.resultURL == scratch.result)

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

        var malformedDigest = environment
        malformedDigest[
            ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest
        ] = String(repeating: "A", count: 64)
        expectConfigurationError(
            .invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: malformedDigest
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

        var wrongBackend = environment
        wrongBackend[
            ProductionAssignmentReplayEnvironmentKey.expectedBackendRevision
        ] = String(repeating: "c", count: 40)
        expectConfigurationError(.backendRevisionMismatch) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: wrongBackend
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

        var overflowingVersion = environment
        overflowingVersion[
            ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion
        ] = String(Int.max)
        expectConfigurationError(
            .invalidEnvironmentValue(
                ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion
            )
        ) {
            _ = try ProductionAssignmentReplayInvocation.parse(
                environment: overflowingVersion
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
    }

    @Test("Child checkpoint and observed Apple revision must match the parent")
    func childConfigurationIdentity() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        var environment = try productionAssignmentReplayEnvironment(
            resultURL: scratch.result
        )
        environment[
            ProductionAssignmentReplayEnvironmentKey.observedAppleRevision
        ] = replayAppleRevision
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

    @Test("Backend, game, and authenticated player identity fail closed")
    // swiftlint:disable:next function_body_length
    func authoritativeIdentity() throws {
        let fixture = try productionAssignmentStartingFixture()
        let configuration = fixture.configuration
        let valid = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: configuration.promptIdentity.gameID,
            backendRevision: configuration.expectedBackendRevision,
            playerID: configuration.promptIdentity.ownerID,
            projection: fixture.projection
        )
        try AssignmentReplayAuthoritativeValidator.validate(
            valid,
            projection: fixture.projection,
            configuration: configuration,
            requiresPlayerIdentity: true
        )

        let wrongBackend = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: valid.gameID,
            backendRevision: String(repeating: "c", count: 40),
            playerID: valid.playerID,
            projection: valid.projection
        )
        #expect(
            throws: ProductionAssignmentReplayError
                .authoritativeBackendRevisionMismatch
        ) {
            try AssignmentReplayAuthoritativeValidator.validate(
                wrongBackend,
                projection: fixture.projection,
                configuration: configuration,
                requiresPlayerIdentity: true
            )
        }

        let wrongGame = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: BoardTestFixtures.gameID("000000000901"),
            backendRevision: valid.backendRevision,
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
                requiresPlayerIdentity: true
            )
        }

        let wrongPlayer = AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: valid.gameID,
            backendRevision: valid.backendRevision,
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
                requiresPlayerIdentity: true
            )
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
                checkpoint: .horrorFirstThenRemainingDamage
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
                gameID: BoardTestFixtures.gameID("000000000901")
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
        #expect(observation?.backendRevision == envelope.game.git)
        #expect(observation?.playerID == nil)

        let answer = Data(#"{"tag":"Answer"}"#.utf8)
        try await connection.send(answer)
        #expect(await baseConnection.sentData == [answer])
        #expect(await recorder.snapshot() == [answer])

        await baseConnection.enqueueSendResult(
            .failure(GameSocketTransportError())
        )
        do {
            try await connection.send(Data("failed".utf8))
            Issue.record("Expected the delegated send failure.")
        } catch is GameSocketTransportError {
            #expect(await recorder.snapshot() == [answer])
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
        #expect(observation?.backendRevision == envelope.game.git)
        #expect(observation?.playerID == envelope.playerID)
    }
}

private func productionAssignmentReplayEnvironment(
    resultURL: URL,
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror
) throws -> [String: String] {
    let promptDigest = try ProductionAssignmentReplayCanonicalJSON.promptDigest(
        DamageAssignmentFixtures.value()
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
        ProductionAssignmentReplayEnvironmentKey.expectedBackendRevision:
            ContractPin.current.backendCommit,
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
        ProductionAssignmentReplayEnvironmentKey.expectedPromptDigest:
            promptDigest,
        ProductionAssignmentReplayEnvironmentKey.expectedPromptVersion: "6",
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
    enemyID: EnemyID = DamageAssignmentFixtures.enemyID
) throws -> ProductionAssignmentReplayConfiguration {
    let profile = try ServerProfile.custom(
        id: #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000777")
        ),
        displayName: "Production assignment replay",
        rawURL: "http://127.0.0.1:3002"
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
        expectedBackendRevision: ContractPin.current.backendCommit,
        expectedAppleRevision: replayAppleRevision,
        expectedContractRevision: ContractPin.current.supportedSchemaRevision,
        expectedCatalogRevision: replayCatalogRevision,
        expectedPromptDigest: promptDigest,
        expectedPromptVersion: promptVersion
    )
}

private func productionAssignmentReplayEvidence(
    checkpoint: ProductionAssignmentReplayCheckpoint =
        .damageFirstThenRemainingHorror,
    gameID: GameID = BoardTestFixtures.gameID()
) throws -> ProductionAssignmentReplayEvidence {
    let playerID = BoardTestFixtures.playerID("000000000001")
    let startDigest = try ProductionAssignmentReplayCanonicalJSON.promptDigest(
        DamageAssignmentFixtures.value()
    )
    return ProductionAssignmentReplayEvidence(
        schemaVersion: ProductionAssignmentReplayEvidence.currentSchemaVersion,
        checkpoint: checkpoint.rawValue,
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
            backend: ContractPin.current.backendCommit,
            apple: replayAppleRevision,
            contract: ContractPin.current.supportedSchemaRevision,
            catalog: replayCatalogRevision
        )
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
