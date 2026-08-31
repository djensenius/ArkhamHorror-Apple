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
}
