@testable import ArkhamHorrorShared
import Testing

@Suite("AssetCacheLimits")
struct AssetCacheLimitsTests {
    @Test("Valid limits with default water marks are accepted")
    func validLimitsAccepted() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: 2048,
            diskBudgetBytes: 4096
        )
        #expect(limits.highWaterMarkRatio == 0.90)
        #expect(limits.lowWaterMarkRatio == 0.75)
    }

    @Test("Water marks exactly at the valid boundary (0, 1, equal) are accepted")
    func boundaryWaterMarksAccepted() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 0,
            maxDimension: 0,
            maxPixelCount: 0,
            memoryBudgetBytes: 0,
            diskBudgetBytes: 0,
            highWaterMarkRatio: 1,
            lowWaterMarkRatio: 0
        )
        #expect(limits.highWaterMarkRatio == 1)
        #expect(limits.lowWaterMarkRatio == 0)
    }

    @Test("A negative byte budget traps rather than silently producing nonsensical accounting")
    func negativeBudgetTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AssetCacheLimits(
                maxEncodedBytes: -1,
                maxDimension: 64,
                maxPixelCount: 4096,
                memoryBudgetBytes: 2048,
                diskBudgetBytes: 4096
            )
        }
    }

    @Test(
        "A low water mark above the high water mark traps rather than silently misordering eviction"
    )
    func lowWaterMarkAboveHighWaterMarkTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AssetCacheLimits(
                maxEncodedBytes: 1024,
                maxDimension: 64,
                maxPixelCount: 4096,
                memoryBudgetBytes: 2048,
                diskBudgetBytes: 4096,
                highWaterMarkRatio: 0.5,
                lowWaterMarkRatio: 0.6
            )
        }
    }

    @Test("A NaN water mark ratio traps rather than silently propagating into eviction math")
    func nanWaterMarkRatioTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AssetCacheLimits(
                maxEncodedBytes: 1024,
                maxDimension: 64,
                maxPixelCount: 4096,
                memoryBudgetBytes: 2048,
                diskBudgetBytes: 4096,
                highWaterMarkRatio: .nan,
                lowWaterMarkRatio: 0.75
            )
        }
    }

    @Test("A water mark ratio outside 0...1 traps rather than silently misordering eviction")
    func outOfRangeWaterMarkRatioTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AssetCacheLimits(
                maxEncodedBytes: 1024,
                maxDimension: 64,
                maxPixelCount: 4096,
                memoryBudgetBytes: 2048,
                diskBudgetBytes: 4096,
                highWaterMarkRatio: 1.5,
                lowWaterMarkRatio: 0.75
            )
        }
    }

    @Test(
        """
        A budget of Int.max with a ratio of 1 computes highWaterMark*Bytes without trapping \
        (Double(Int.max) alone already rounds up to 2^63, which Int(_:) cannot represent), \
        and the result never exceeds the original budget
        """
    )
    func maxBudgetWithRatioOneNeverTraps() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: .max,
            diskBudgetBytes: .max,
            highWaterMarkRatio: 1,
            lowWaterMarkRatio: 1
        )
        #expect(limits.highWaterMarkMemoryBytes <= .max)
        #expect(limits.lowWaterMarkMemoryBytes <= .max)
        #expect(limits.highWaterMarkDiskBytes <= .max)
        #expect(limits.lowWaterMarkDiskBytes <= .max)
    }

    @Test(
        """
        A budget one below Int.max with a high-water ratio just under 1 computes a water mark \
        that never traps and never exceeds the original budget, exercising the boundary just \
        below where Double(budget) itself starts rounding up past the true Int value
        """
    )
    func nearMaxBudgetWithNearOneRatioNeverExceedsBudget() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: .max - 1,
            diskBudgetBytes: .max - 1,
            highWaterMarkRatio: 0.999_999_999_9,
            lowWaterMarkRatio: 0.5
        )
        #expect(limits.highWaterMarkMemoryBytes <= limits.memoryBudgetBytes)
        #expect(limits.highWaterMarkDiskBytes <= limits.diskBudgetBytes)
    }

    @Test("An ordinary, non-extreme budget still computes the expected exact water mark bytes")
    func ordinaryBudgetComputesExactWaterMarkBytes() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: 1000,
            diskBudgetBytes: 2000,
            highWaterMarkRatio: 0.9,
            lowWaterMarkRatio: 0.75
        )
        #expect(limits.highWaterMarkMemoryBytes == 900)
        #expect(limits.lowWaterMarkMemoryBytes == 750)
        #expect(limits.highWaterMarkDiskBytes == 1800)
        #expect(limits.lowWaterMarkDiskBytes == 1500)
    }

    @Test(
        """
        The authority-record count budget derives its water marks from the same ratios, by the \
        same rule, as the byte \
        budgets do -- including at a budget one below Int.max with a ratio just under 1, where a \
        naive Double round- \
        trip would exceed the budget it is supposed to bound.
        """
    )
    func authorityRecordCountWaterMarksFollowTheByteBudgetRule() {
        let ordinary = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: 1000,
            diskBudgetBytes: 2000,
            maxAuthorityRecordCount: 1000,
            highWaterMarkRatio: 0.9,
            lowWaterMarkRatio: 0.75
        )
        #expect(ordinary.highWaterMarkAuthorityRecordCount == 900)
        #expect(ordinary.lowWaterMarkAuthorityRecordCount == 750)

        let extreme = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: 1000,
            diskBudgetBytes: 2000,
            maxAuthorityRecordCount: .max - 1,
            highWaterMarkRatio: 0.999_999_999_9,
            lowWaterMarkRatio: 0.5
        )
        #expect(extreme.highWaterMarkAuthorityRecordCount <= extreme.maxAuthorityRecordCount)
        #expect(
            extreme.lowWaterMarkAuthorityRecordCount
                <= extreme.highWaterMarkAuthorityRecordCount
        )
    }

    @Test("A negative authority-record budget traps, exactly like a negative byte budget")
    func negativeAuthorityRecordCountTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AssetCacheLimits(
                maxEncodedBytes: 1024,
                maxDimension: 64,
                maxPixelCount: 4096,
                memoryBudgetBytes: 2048,
                diskBudgetBytes: 4096,
                maxAuthorityRecordCount: -1
            )
        }
    }

    @Test(
        """
        The directory-entry flood ceiling leaves real headroom above everything the production \
        budgets could \
        themselves legitimately produce: every authority record at its own cap, plus every content \
        entry the disk byte \
        budget could hold even if each one were implausibly tiny, plus both of that entry's files.
        """
    )
    func floodCeilingLeavesHeadroomAboveEveryLegitimateProductionPopulation() {
        let production = AssetCacheLimits.production
        let maximumContentEntries =
            production.diskBudgetBytes / AssetCacheLimits.minimumAccountedContentEntryBytes
        let legitimatePopulation =
            production.maxAuthorityRecordCount + 2 * maximumContentEntries
        #expect(production.maxAccountableDirectoryEntryCount > legitimatePopulation)
        #expect(
            production.maxAccountableDirectoryEntryCount >= 2 * legitimatePopulation,
            "The ceiling is a generous multiple, not a value a full cache could brush against"
        )
    }

    @Test(
        """
        The flood ceiling saturates rather than overflowing when the budgets it is derived from \
        are themselves near \
        Int.max.
        """
    )
    func floodCeilingSaturatesAtExtremeBudgets() {
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 64,
            maxPixelCount: 4096,
            memoryBudgetBytes: .max,
            diskBudgetBytes: .max,
            maxAuthorityRecordCount: .max
        )
        #expect(limits.maxAccountableDirectoryEntryCount == .max)
    }
}
