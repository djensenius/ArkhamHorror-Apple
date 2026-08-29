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
}
