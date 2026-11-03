@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB write-back failed pushes and stale confirmations")
@MainActor
struct ArkhamDBWriteBackFailedPushTests {
    private let deckA = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    private let deckB = DeckID(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

    private func loaded(
        _ rows: [ArkhamDBWriteBackStatus], then responses: [(Int, Data)] = []
    ) async throws -> (ArkhamDBViewModel, ArkhamDBScriptedTransport) {
        let transport = try ArkhamDBScriptedTransport(
            [(200, writeBackStatusData(rows))] + responses
        )
        let model = ArkhamDBViewModel(
            profile: .hosted, service: ArkhamDBService(transport: transport),
            authentication: nil, tokenProvider: { arkhamDBTestContext },
            supportsWriteBack: true
        )
        await model.refreshStatus()
        return (model, transport)
    }

    @Test(
        "Failed creation intents offer Retry, keep-remote and save-as-new, never overwrite",
        arguments: ["pushUncertain", "writeBackDisabled"]
    )
    func failedCreationIntent(error: String) async throws {
        let failed = writeBackRow(deckA, state: .failed, error: error)
        #expect(failed.allowedResolutions == [.keepRemote, .saveAsNew])
        #expect(failed.canRetry && failed.opensResolution && failed.blockedReason == nil)
        #expect(writeBackRow(deckA, enabled: false, state: .failed, error: error)
            .allowedResolutions.isEmpty)
        let pending = try ContractJSON.encode([writeBackRow(deckA, state: .pending)])
        let (model, transport) = try await loaded([failed], then: [(200, pending)])
        model.openResolution(deckA)
        #expect(model.resolvingStatus == failed)
        await model.chooseResolution(.overwrite, for: deckA)
        #expect(model.pendingConfirmation == nil)
        await model.chooseResolution(.saveAsNew, for: deckA)
        #expect(await transport.requests.count == 1)
        await model.confirmPendingResolution()
        let request = try #require(await transport.requests.last)
        #expect(await transport.requests.count == 2)
        #expect(request.url?.path.hasSuffix("/resolve-conflict") == true)
        #expect(try writeBackBody(request) == .object([
            "resolution": .string("saveAsNew"), "confirmed": .bool(true),
        ]))

        let (keeping, keepTransport) = try await loaded([failed], then: [(200, pending)])
        await keeping.chooseResolution(.keepRemote, for: deckA)
        #expect(try writeBackBody(#require(await keepTransport.requests.last)) == .object([
            "resolution": .string("keepRemote"), "confirmed": .bool(false),
        ]))
    }

    @Test("Other failures offer Retry only", arguments: [nil, "remoteUnavailable"])
    func plainFailure(error: String?) async throws {
        let failed = writeBackRow(deckA, state: .failed, error: error)
        #expect(failed.canRetry && failed.allowedResolutions.isEmpty && !failed.opensResolution)
        let (model, transport) = try await loaded([failed])
        model.openResolution(deckA)
        #expect(model.resolvingDeckID == nil)
        await model.chooseResolution(.keepRemote, for: deckA)
        #expect(await transport.requests.count == 1)
    }

    @Test("A validationFailed push is fenced: no retry or resolution is offered or sent")
    func validationFence() async throws {
        let fenced = writeBackRow(deckA, state: .failed, error: "validationFailed")
        #expect(!fenced.canRetry && fenced.allowedResolutions.isEmpty)
        #expect(fenced.statusText == arkhamDBLocalized("writeBack.state.failedValidation"))
        let (model, transport) = try await loaded([fenced])
        await model.retryWriteBack(deckA)
        for resolution in ArkhamDBWriteBackResolution.allCases {
            await model.chooseResolution(resolution, for: deckA)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("A confirmation never survives closing the sheet or opening another deck")
    func staleConfirmation() async throws {
        let (model, transport) = try await loaded([
            writeBackRow(deckA, state: .conflict, reason: .remoteChanged),
            writeBackRow(deckB, state: .conflict, reason: .remoteChanged),
        ])
        model.openResolution(deckA)
        await model.chooseResolution(.overwrite, for: deckA)
        #expect(model.pendingConfirmation?.deckID == deckA)
        model.openResolution(deckB)
        #expect(model.pendingConfirmation == nil)
        await model.confirmPendingResolution()

        await model.chooseResolution(.overwrite, for: deckB)
        model.closeResolution()
        #expect(model.pendingConfirmation == nil && model.resolvingDeckID == nil)

        // Even if one leaks, it is only confirmed for the deck whose sheet is open.
        model.openResolution(deckB)
        model.pendingConfirmation = ArkhamDBPendingResolution(deckID: deckA, resolution: .overwrite)
        await model.confirmPendingResolution()
        #expect(await transport.requests.count == 1)
    }

    @Test("A confirmation dismissed before its Task runs is still sent exactly once")
    func capturedConfirmationSurvivesDismissal() async throws {
        let pending = try ContractJSON.encode([writeBackRow(deckA, state: .pending)])
        let (model, transport) = try await loaded(
            [writeBackRow(deckA, state: .conflict, reason: .remoteChanged)],
            then: [(200, pending)]
        )
        model.openResolution(deckA)
        await model.chooseResolution(.overwrite, for: deckA)
        let captured = try #require(model.pendingConfirmation)
        model.cancelPendingResolution()
        await model.confirmPendingResolution(captured)
        await model.confirmPendingResolution(captured)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(try writeBackBody(#require(requests.last)) == .object([
            "resolution": .string("overwrite"), "confirmed": .bool(true),
        ]))
    }

    @Test("A captured confirmation for another deck or a refused resolution sends nothing")
    func capturedConfirmationRevalidated() async throws {
        let (model, transport) = try await loaded([
            writeBackRow(deckA, state: .conflict, reason: .remoteChanged),
            writeBackRow(deckB, state: .conflict, reason: .campaignChanged),
        ])
        model.openResolution(deckA)
        await model.chooseResolution(.overwrite, for: deckA)
        let other = try #require(model.pendingConfirmation)
        model.openResolution(deckB)
        await model.confirmPendingResolution(other)
        // deckB's status does not allow overwrite.
        await model.confirmPendingResolution(
            ArkhamDBPendingResolution(deckID: deckB, resolution: .overwrite)
        )
        #expect(await transport.requests.count == 1)
    }
}
