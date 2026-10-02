/// Whether the board currently has an active scenario to show a chaos bag for at all.
/// `ChaosBag` itself always decodes fully typed (it has no `unknown`/deferred wire
/// shape), so the only two real states are "no active scenario" (a `This`-only campaign
/// screen) and "an active scenario's chaos bag" — which may itself be legitimately empty.
/// Collapsing these two into a single ``BoardChaosBagSummary`` (as an earlier revision of
/// this projection did) made a genuinely empty, fully-decoded bag indistinguishable from
/// having no scenario at all, so both rendered the same "not supported" notice — this
/// type exists specifically to keep that distinction explicit end to end.
enum BoardChaosBagState: Sendable, Equatable {
    case noActiveScenario
    case scenario(BoardChaosBagSummary)

    /// The three mutually-exclusive, fully-representable display states a chaos bag can
    /// ever be in — the single source of truth both ``BoardChaosBagView`` (on-screen) and
    /// ``BoardAccessibility/summary(chaosBag:)`` (VoiceOver) branch on, so a test can
    /// assert the same categorization both surfaces actually render/announce without
    /// instantiating either view.
    var displayState: BoardChaosBagDisplayState {
        switch self {
        case .noActiveScenario:
            .noActiveScenario
        case let .scenario(summary):
            summary.isEntirelyEmpty ? .empty : .populated(summary)
        }
    }
}

/// See ``BoardChaosBagState/displayState``.
enum BoardChaosBagDisplayState: Sendable, Equatable {
    case noActiveScenario
    case empty
    case populated(BoardChaosBagSummary)
}
