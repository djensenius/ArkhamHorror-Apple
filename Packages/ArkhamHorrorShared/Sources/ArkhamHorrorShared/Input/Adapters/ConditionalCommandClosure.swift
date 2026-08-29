/// The platform-independent decision behind an *identity-preserving*
/// conditional SwiftUI command modifier: many system command modifiers
/// (`.onExitCommand(perform:)`, `.onPlayPauseCommand(perform:)`, and others)
/// accept an **optional** closure, where `nil` is Apple's own documented
/// equivalent of "this method was never called" — letting the platform's
/// system default behavior run instead of ours.
///
/// Selecting `nil` vs. a real closure by *argument value* (as this function
/// does), rather than by conditionally attaching/detaching the modifier
/// itself (e.g. `if condition { content.onExitCommand { ... } } else {
/// content }`), is what lets a command's installation be runtime-
/// conditional while the wrapped view's own structural identity — and thus
/// any `@FocusState`/`@GestureState` nested inside it — stays completely
/// stable across every toggle: the modifier's own type never changes, only
/// this one argument's value does.
///
/// Deliberately not tied to any specific command or platform: this decision
/// itself has zero platform dependency, unlike its concrete tvOS-only
/// consumer (``SemanticSiriRemoteInput``, entirely `#if os(tvOS)`-gated and
/// so not directly testable via `swift test` on a non-tvOS host) — isolating
/// it here gives the actual decision direct, cross-platform unit test
/// coverage.
func conditionalCommandClosure(
    isEnabled: Bool, perform: @escaping () -> Void
) -> (() -> Void)? {
    isEnabled ? perform : nil
}
