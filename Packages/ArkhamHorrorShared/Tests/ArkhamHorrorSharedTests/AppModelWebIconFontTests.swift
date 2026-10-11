@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("AppModel web icon font loading")
struct AppModelWebIconFontTests {
    @Test("Web icon fonts wait for a compatible capability probe")
    func fontLoadWaitsForCompatibleProbe() async {
        let probe = GatedCapabilityProbe()
        let loader = RecordingWebIconFontLoader()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: loader
        )

        await probe.waitUntilPending(1)
        #expect(await loader.callCount == 0)

        await probe.resumeOldest(with: .compatible(
            capabilities: ["websockets.authorization-header"]
        ))
        await model.flowTask?.value
        await model.webIconFontTask?.value

        #expect(await loader.callCount == 1)
        #expect(await loader.requestedProfileIDs == [ServerProfile.hosted.id])
    }

    @Test("AppModel default web icon font loader is disabled")
    func defaultWebIconFontLoaderDoesNoProductionWork() async {
        let probe = GatedCapabilityProbe()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        defer { model.webIconFontTask?.cancel() }

        await probe.waitUntilPending(1)
        #expect(model.webIconFontLoader is DisabledWebIconFontLoader)

        await probe.resumeOldest(with: .compatible(
            capabilities: ["websockets.authorization-header"]
        ))
        await model.flowTask?.value
        await model.webIconFontTask?.value

        #expect(model.webIconFontAvailability == WebIconFontAvailability())
    }

    @Test("Legacy and incompatible probes never start a web icon font load")
    func unsupportedCompatibilityOutcomesDoNotStartFontLoads() async {
        let legacyLoader = RecordingWebIconFontLoader()
        let legacyModel = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: legacyLoader
        )
        await legacyModel.flowTask?.value
        #expect(await legacyLoader.callCount == 0)
        #expect(legacyModel.webIconFontTask == nil)

        let incompatibleLoader = RecordingWebIconFontLoader()
        let incompatibleModel = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.incompatible(
                reason: .apiBasePathMismatch(server: "/wrong", expected: "/api/v1")
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: incompatibleLoader
        )
        await incompatibleModel.flowTask?.value
        #expect(await incompatibleLoader.callCount == 0)
        #expect(incompatibleModel.webIconFontTask == nil)
    }

    @Test("Retry starts a web icon font load after a compatible re-probe")
    func retryStartsFontLoadAfterCompatibleReprobe() async {
        let probe = QueuedCapabilityProbe([
            .outcome(.incompatible(
                reason: .apiBasePathMismatch(server: "/wrong", expected: "/api/v1")
            )),
            .outcome(.compatible(capabilities: ["websockets.authorization-header"])),
        ])
        let loader = RecordingWebIconFontLoader()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: loader
        )

        await model.flowTask?.value
        #expect(await loader.callCount == 0)

        model.retry()
        await model.flowTask?.value
        await model.webIconFontTask?.value

        #expect(await loader.callCount == 1)
        #expect(await loader.requestedProfileIDs == [ServerProfile.hosted.id])
        #expect(await probe.callCount == 2)
    }

    @Test("Endpoint edits restart the web icon font load")
    func endpointEditRestartsFontLoad() async {
        let loader = RecordingWebIconFontLoader()
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: ["websockets.authorization-header"]
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: loader
        )

        await model.flowTask?.value
        await model.webIconFontTask?.value
        #expect(await loader.requestedProfileIDs == [sampleCustomProfile.id])

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: "Renamed",
            rawURL: "https://renamed.example.com"
        )
        await model.profileManagementTask?.value
        await model.flowTask?.value
        await model.webIconFontTask?.value

        #expect(await loader.requestedProfileIDs == [
            sampleCustomProfile.id, sampleCustomProfile.id,
        ])
    }

    @Test("A stale web icon font report cannot survive a profile switch")
    func staleWebIconFontReportAfterProfileSwitchIsIgnored() async throws {
        let probe = GatedCapabilityProbe()
        let loader = GatedWebIconFontLoader()
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            webIconFontLoader: loader
        )

        await probe.waitUntilPending(1)
        await probe.resumeOldest(with: .compatible(
            capabilities: ["websockets.authorization-header"]
        ))
        await loader.waitUntilPending(1)
        let staleTask = model.webIconFontTask

        model.selectProfile(sampleCustomProfile)
        await probe.waitUntilPending(1)
        await probe.resumeNewest(with: .compatible(
            capabilities: ["websockets.authorization-header"]
        ))
        await loader.waitUntilPending(2)

        let staleReport = WebIconFontLoadReport(registrations: [
            .arkham: registration(.arkham, postScriptName: "StaleArkham"),
        ], failures: [:])
        await loader.resumeOldest(with: staleReport)
        await staleTask?.value
        #expect(model.webIconFontAvailability == WebIconFontAvailability())

        let currentReport = WebIconFontLoadReport(registrations: [
            .arkham: registration(.arkham, postScriptName: "CurrentArkham"),
        ], failures: [:])
        await loader.resumeNewest(with: currentReport)
        await model.webIconFontTask?.value

        let glyph = try #require(StoryIconGlyph.all.first { $0.family == .arkham })
        #expect(model.webIconFontAvailability.postScriptName(for: glyph) == "CurrentArkham")
        #expect(await loader.requestedProfileIDs == [
            ServerProfile.hosted.id, sampleCustomProfile.id,
        ])
    }

    private func registration(
        _ family: WebIconFontFamily,
        postScriptName: String
    ) -> WebIconFontRegistration {
        WebIconFontRegistration(
            family: family,
            postScriptName: postScriptName,
            supportedScalars: Set(StoryIconGlyph.all.compactMap { glyph in
                glyph.family == family ? glyph.scalar.value : nil
            })
        )
    }
}

private actor QueuedCapabilityProbe: CapabilityProbing {
    enum Step {
        case outcome(CompatibilityOutcome)
        case failure(any Error & Sendable)
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func probe(_: ServerProfile) async throws -> CompatibilityOutcome {
        callCount += 1
        guard !steps.isEmpty else { throw CapabilityProbeError.nonHTTPResponse }
        switch steps.removeFirst() {
        case let .outcome(outcome):
            return outcome
        case let .failure(error):
            throw error
        }
    }
}
