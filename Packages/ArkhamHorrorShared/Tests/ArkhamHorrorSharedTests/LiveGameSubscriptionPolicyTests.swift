#if canImport(SwiftUI)
    @testable import ArkhamHorrorShared
    import SwiftUI
    import Testing

    /// Deterministic coverage for
    /// ``LiveGameSubscriptionPolicy/shouldBeSubscribed(isViewVisible:scenePhase:)``,
    /// the pure visibility/scene-phase-to-subscription mapping ``LiveGameView`` drives
    /// its `onAppear`/`onDisappear`/scene-phase-change subscription lifecycle from.
    @Suite("LiveGameSubscriptionPolicy")
    struct LiveGameSubscriptionPolicyTests {
        @Test("A visible view in the active scene phase should be subscribed")
        func visibleAndActiveShouldBeSubscribed() {
            #expect(
                LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: true, scenePhase: .active
                )
            )
        }

        @Test("An invisible view should never be subscribed, regardless of scene phase")
        func invisibleViewShouldNeverBeSubscribed() {
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: false, scenePhase: .active
                )
            )
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: false, scenePhase: .inactive
                )
            )
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: false, scenePhase: .background
                )
            )
        }

        @Test("A visible view should not be subscribed while backgrounded or inactive")
        func visibleButBackgroundedShouldNotBeSubscribed() {
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: true, scenePhase: .background
                )
            )
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: true, scenePhase: .inactive
                )
            )
        }
    }
#endif
