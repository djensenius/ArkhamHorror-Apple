#if canImport(SwiftUI)
    @testable import ArkhamHorrorShared
    import SwiftUI
    import Testing

    /// Deterministic coverage for
    /// ``LiveGameSubscriptionPolicy/shouldBeSubscribed(isViewVisible:scenePhase:)``,
    /// the pure visibility/scene-phase-to-subscription mapping ``LiveGameView`` drives
    /// its `onAppear`/`onDisappear`/scene-phase-change subscription lifecycle from.
    ///
    /// `.inactive` (a window losing key focus while still visible -- multi-window
    /// focus handoff on macOS/iPadOS, Stage Manager, Split View, Control Center, or
    /// any other transient, non-backgrounded interruption) is deliberately treated
    /// exactly like `.active`: only an actually invisible view, or an actually
    /// `.background`-phased scene, withdraws its subscription. See this policy's own
    /// documentation for why requiring `.active` previously caused a spurious full
    /// session teardown/expensive REST-refetch-and-reconnect thrash on every simple
    /// focus toggle, and could even briefly empty a shared game's subscriber set
    /// during a two-window focus handoff.
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

        @Test("""
        A visible view in the inactive scene phase (focus handoff, Stage Manager/\
        Split View, Control Center, or any other transient non-backgrounded \
        interruption) remains subscribed
        """)
        func visibleAndInactiveRemainsSubscribed() {
            #expect(
                LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: true, scenePhase: .inactive
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

        @Test("A visible view should not be subscribed while actually backgrounded")
        func visibleButBackgroundedShouldNotBeSubscribed() {
            #expect(
                !LiveGameSubscriptionPolicy.shouldBeSubscribed(
                    isViewVisible: true, scenePhase: .background
                )
            )
        }
    }
#endif
