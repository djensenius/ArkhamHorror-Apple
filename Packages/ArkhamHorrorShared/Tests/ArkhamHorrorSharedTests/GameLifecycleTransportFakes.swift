@testable import ArkhamHorrorShared
import Foundation

// MARK: - HTTPTransport fakes shared by GameLifecycleService test files

/// Records the last request/body and returns a canned response.
actor GameLifecycleRecordingTransport: HTTPTransport {
    private(set) var capturedRequest: URLRequest?
    private(set) var capturedBody: Data?
    private let stubData: Data
    private let stubResponse: URLResponse

    init(data: Data, response: URLResponse) {
        stubData = data
        stubResponse = response
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await record(request)
        return (stubData, stubResponse)
    }

    private func record(_ request: URLRequest) {
        capturedRequest = request
        capturedBody = request.httpBody
    }
}

struct GameLifecycleFailingTransport: HTTPTransport {
    let error: any Error & Sendable
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

struct GameLifecycleTransportFailure: Error, Sendable {}

typealias GameLifecycleGateContinuation = CheckedContinuation<(Data, URLResponse), any Error>
typealias GameLifecycleVoidContinuation = CheckedContinuation<Void, any Error>

/// Blocks `data(for:)` until the caller releases the gate, so a task is guaranteed
/// mid-flight before cancellation is injected.
actor GameLifecycleGatedTransport: HTTPTransport {
    private var pendingGate: GameLifecycleGateContinuation?
    private var gateWaiter: CheckedContinuation<GameLifecycleGateContinuation, Never>?

    func awaitGate() async -> GameLifecycleGateContinuation {
        if let gate = pendingGate {
            pendingGate = nil
            return gate
        }
        return await withCheckedContinuation { gateWaiter = $0 }
    }

    private func deliverGate(_ gate: GameLifecycleGateContinuation) {
        if let waiter = gateWaiter {
            waiter.resume(returning: gate)
            gateWaiter = nil
        } else {
            pendingGate = gate
        }
    }

    nonisolated func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { gate in
            Task { await self.deliverGate(gate) }
        }
    }
}
