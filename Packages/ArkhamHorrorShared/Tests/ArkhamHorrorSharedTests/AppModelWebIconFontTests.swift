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

        await probe.resumeOldest(with: .compatible(capabilities: ["websockets.authorization-header"]))
        await model.flowTask?.value
        await model.webIconFontTask?.value

        #expect(await loader.callCount == 1)
        #expect(await loader.requestedProfileIDs == [ServerProfile.hosted.id])
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
        await probe.resumeOldest(with: .compatible(capabilities: ["websockets.authorization-header"]))
        await loader.waitUntilPending(1)
        let staleTask = model.webIconFontTask

        model.selectProfile(sampleCustomProfile)
        await probe.waitUntilPending(1)
        await probe.resumeNewest(with: .compatible(capabilities: ["websockets.authorization-header"]))
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
        #expect(await loader.requestedProfileIDs == [ServerProfile.hosted.id, sampleCustomProfile.id])
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
