@testable import ArkhamHorrorShared
import Foundation

actor AssignmentReplayCapabilityTransport: CapabilityProbeTransport {
    private let base: any CapabilityProbeTransport
    private var latestResponseData: Data?

    init(base: any CapabilityProbeTransport = URLSessionTransport()) {
        self.base = base
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = try await base.data(for: request)
        latestResponseData = response.0
        return response
    }

    func decodedCapabilities() throws -> ServerCapabilities {
        guard let latestResponseData else {
            throw ProductionAssignmentReplayError.capabilitiesUnavailable
        }
        do {
            return try ContractJSON.decode(
                ServerCapabilities.self,
                from: latestResponseData
            )
        } catch {
            throw ProductionAssignmentReplayError.capabilitiesUnavailable
        }
    }
}

enum AssignmentReplayObservationSource: Sendable, Equatable {
    case rest
    case socket
}

struct AssignmentReplayAuthoritativeObservation: Sendable, Equatable {
    let source: AssignmentReplayObservationSource
    let gameID: GameID
    let gameRevision: String
    let playerID: PlayerID?
    let projection: BoardProjection
}

actor AssignmentReplayAuthoritativeRecorder {
    private var observations: [AssignmentReplayAuthoritativeObservation] = []

    func recordREST(_ envelope: GetGameEnvelope) {
        observations.append(AssignmentReplayAuthoritativeObservation(
            source: .rest,
            gameID: envelope.game.id,
            gameRevision: envelope.game.git,
            playerID: envelope.playerID,
            projection: BoardProjectionBuilder.makeProjection(from: envelope.game)
        ))
    }

    func recordSocket(_ snapshot: PublicGameSnapshot) {
        observations.append(AssignmentReplayAuthoritativeObservation(
            source: .socket,
            gameID: snapshot.id,
            gameRevision: snapshot.git,
            playerID: nil,
            projection: BoardProjectionBuilder.makeProjection(from: snapshot)
        ))
    }

    func latest(
        gameID: GameID,
        questionVersion: Int,
        source: AssignmentReplayObservationSource? = nil
    ) -> AssignmentReplayAuthoritativeObservation? {
        observations.reversed().first {
            $0.gameID == gameID
                && $0.projection.counters.scenarioSteps == questionVersion
                && (source == nil || $0.source == source)
        }
    }
}

struct AssignmentReplayRecordingGameTransport: HTTPTransport {
    let base: any HTTPTransport
    let recorder: AssignmentReplayAuthoritativeRecorder

    init(
        base: any HTTPTransport = URLSessionTransport(),
        recorder: AssignmentReplayAuthoritativeRecorder =
            AssignmentReplayAuthoritativeRecorder()
    ) {
        self.base = base
        self.recorder = recorder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = try await base.data(for: request)
        if let envelope = replayGameEnvelope(
            for: request,
            response: response
        ) {
            await recorder.recordREST(envelope)
        }
        return response
    }
}

private func replayGameEnvelope(
    for request: URLRequest,
    response: (Data, URLResponse)
) -> GetGameEnvelope? {
    guard request.httpMethod == "GET",
          let http = response.1 as? HTTPURLResponse,
          (200 ... 299).contains(http.statusCode)
    else {
        return nil
    }
    return try? ContractJSON.decode(
        GetGameEnvelope.self,
        from: response.0
    )
}

final class ProductionAssignmentReplaySocketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var successfulSends: [Data] = []

    func recordSuccessfulSend(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        successfulSends.append(data)
    }

    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return successfulSends
    }
}

struct AssignmentReplayRecordingSocketFactory: GameSocketFactory {
    let base: any GameSocketFactory
    let recorder: ProductionAssignmentReplaySocketRecorder
    let authoritativeRecorder: AssignmentReplayAuthoritativeRecorder

    init(
        base: any GameSocketFactory = URLSessionGameSocketFactory(),
        recorder: ProductionAssignmentReplaySocketRecorder =
            ProductionAssignmentReplaySocketRecorder(),
        authoritativeRecorder: AssignmentReplayAuthoritativeRecorder =
            AssignmentReplayAuthoritativeRecorder()
    ) {
        self.base = base
        self.recorder = recorder
        self.authoritativeRecorder = authoritativeRecorder
    }

    func connect(to url: URL) async throws -> any GameSocketConnection {
        let connection = try await base.connect(to: url)
        return AssignmentReplaySocketConnection(
            base: connection,
            recorder: recorder,
            authoritativeRecorder: authoritativeRecorder
        )
    }
}

private struct AssignmentReplaySocketConnection: GameSocketConnection {
    let base: any GameSocketConnection
    let recorder: ProductionAssignmentReplaySocketRecorder
    let authoritativeRecorder: AssignmentReplayAuthoritativeRecorder

    func nextEvent() async throws -> GameSocketEvent {
        let event = try await base.nextEvent()
        if let snapshot = replaySnapshot(from: event) {
            await authoritativeRecorder.recordSocket(snapshot)
        }
        return event
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
        recorder.recordSuccessfulSend(data)
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        base.close(code: code, reason: reason)
    }
}

private func replaySnapshot(
    from event: GameSocketEvent
) -> PublicGameSnapshot? {
    guard case let .message(data) = event,
          let update = try? ContractJSON.decode(
              BoardSnapshotUpdate.self,
              from: data
          ),
          case let .snapshot(snapshot) = update
    else {
        return nil
    }
    return snapshot
}

enum AssignmentContinuationReplayDriver {
    static func victim() throws -> ProductionReplayVictim {
        try ProductionReplayVictim(
            moduleName: "ArkhamHorrorSharedTests",
            suiteName: "AssignmentContinuationReplayVictimSuite",
            functionName: "productionAssignmentContinuationReplayVictim"
        )
    }

    static func run(
        invocation: ProductionAssignmentReplayInvocation,
        hostArguments: [String] = CommandLine.arguments,
        appleRevisionProvider: () throws -> String = {
            try ProductionAssignmentReplayGitRevision.current()
        },
        deadlineRunner: ProductionReplayDeadlineRunner = {
            try SubprocessDeadlineGuard.runFiltered(
                victimFilter: $0,
                additionalEnvironment: $1,
                deadlineSeconds: $2,
                hostArguments: $3
            )
        }
    ) throws -> ProductionReplayRunResult {
        let observedAppleRevision = try appleRevisionProvider()
        guard observedAppleRevision
            == invocation.configuration.expectedAppleRevision
        else {
            throw AssignmentReplayConfigurationError.appleRevisionMismatch
        }
        var childEnvironment = try invocation.configuration.childEnvironment(
            observedAppleRevision: observedAppleRevision
        )
        childEnvironment[ProductionAssignmentReplayEnvironmentKey.resultPath] =
            invocation.resultURL.path
        let input = try ProductionReplayInput(
            checkpoint: invocation.configuration.checkpoint,
            resultURL: invocation.resultURL,
            additionalEnvironment: childEnvironment
        )
        return try ProductionReplayDriver.run(
            victim: victim(),
            input: input,
            deadlineSeconds: invocation.configuration.deadlineSeconds,
            hostArguments: hostArguments,
            artifactValidator: { data in
                let artifact = try AssignmentReplayEvidenceArtifact
                    .decodeAndValidate(data)
                try artifact.evidence.validate(
                    configuration: invocation.configuration
                )
            },
            deadlineRunner: deadlineRunner
        )
    }
}
