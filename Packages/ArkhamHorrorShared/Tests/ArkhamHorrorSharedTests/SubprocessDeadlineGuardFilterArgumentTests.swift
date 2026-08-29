import Testing

/// Direct, mutation-resistant coverage for ``SubprocessDeadlineGuard/replacingFilterArgument
/// (in:with:)``, isolated from the full subprocess-launch machinery it supports. A review
/// of the original implementation found it corrupted the unpaired-trailing-`--filter` case
/// into `... --filter --filter <victim>` (appending a *second* flag instead of pairing the
/// dangling one with a value); these tests assert the exact resulting argument array for
/// every relevant shape, not just "doesn't crash".
@Suite("SubprocessDeadlineGuard.replacingFilterArgument")
struct FilterArgumentReplacementTests {
    @Test("No existing --filter appends a new, paired --filter flag and value")
    func noExistingFilterAppendsPairedFlag() {
        let result = SubprocessDeadlineGuard.replacingFilterArgument(
            in: ["--package-path", "Packages/ArkhamHorrorShared"],
            with: "victimName"
        )
        #expect(result == [
            "--package-path", "Packages/ArkhamHorrorShared", "--filter", "victimName",
        ])
    }

    @Test("An existing paired --filter has only its value replaced, in place")
    func existingPairedFilterReplacesValueInPlace() {
        let result = SubprocessDeadlineGuard.replacingFilterArgument(
            in: ["--package-path", "Packages/ArkhamHorrorShared", "--filter", "oldFilter"],
            with: "victimName"
        )
        #expect(result == [
            "--package-path", "Packages/ArkhamHorrorShared", "--filter", "victimName",
        ])
    }

    @Test("An existing paired --filter in the middle of the arguments replaces only its own value")
    func existingPairedFilterInMiddleReplacesOnlyItsOwnValue() {
        let result = SubprocessDeadlineGuard.replacingFilterArgument(
            in: ["--filter", "oldFilter", "--package-path", "Packages/ArkhamHorrorShared"],
            with: "victimName"
        )
        #expect(result == [
            "--filter", "victimName", "--package-path", "Packages/ArkhamHorrorShared",
        ])
    }

    @Test("A dangling trailing --filter with no value is paired with the victim, never duplicated")
    func unpairedTrailingFilterIsPairedNotDuplicated() {
        let result = SubprocessDeadlineGuard.replacingFilterArgument(
            in: ["--package-path", "Packages/ArkhamHorrorShared", "--filter"],
            with: "victimName"
        )
        #expect(result == [
            "--package-path", "Packages/ArkhamHorrorShared", "--filter", "victimName",
        ])
        // The regression this guards against: exactly one "--filter" token in the result.
        #expect(result.filter { $0 == "--filter" }.count == 1)
    }

    @Test("An empty argument list appends a new, paired --filter flag and value")
    func emptyArgumentsAppendsPairedFlag() {
        let result = SubprocessDeadlineGuard.replacingFilterArgument(in: [], with: "victimName")
        #expect(result == ["--filter", "victimName"])
    }
}
