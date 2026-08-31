/// Configurable resource limits enforced across content validation and
/// caching. Production code uses ``production``; tests inject small values
/// (e.g. a handful of bytes/entries) to exercise cap and eviction logic
/// deterministically without allocating real budgets.
struct AssetCacheLimits: Sendable, Equatable {
    /// Maximum encoded (compressed, on-the-wire) byte size accepted for a
    /// single asset. Enforced incrementally while bytes arrive.
    let maxEncodedBytes: Int
    /// Maximum accepted width or height, in pixels.
    let maxDimension: Int
    /// Maximum accepted total decoded pixel count (width × height).
    let maxPixelCount: Int
    /// Total in-memory cache budget, in bytes (payload plus each entry's
    /// actual serialized-metadata-JSON byte count — not a fixed overhead
    /// estimate; see ``CachedAsset/accountedByteCount``).
    let memoryBudgetBytes: Int
    /// Total on-disk cache budget, in bytes (payload + serialized metadata
    /// size for every entry).
    let diskBudgetBytes: Int
    /// Eviction begins once total usage reaches this fraction of the
    /// relevant budget.
    let highWaterMarkRatio: Double
    /// Eviction (oldest-access-first) continues until usage falls to this
    /// fraction of the relevant budget.
    let lowWaterMarkRatio: Double

    init(
        maxEncodedBytes: Int,
        maxDimension: Int,
        maxPixelCount: Int,
        memoryBudgetBytes: Int,
        diskBudgetBytes: Int,
        highWaterMarkRatio: Double = 0.90,
        lowWaterMarkRatio: Double = 0.75
    ) {
        precondition(maxEncodedBytes >= 0, "maxEncodedBytes must not be negative")
        precondition(maxDimension >= 0, "maxDimension must not be negative")
        precondition(maxPixelCount >= 0, "maxPixelCount must not be negative")
        precondition(memoryBudgetBytes >= 0, "memoryBudgetBytes must not be negative")
        precondition(diskBudgetBytes >= 0, "diskBudgetBytes must not be negative")
        precondition(
            highWaterMarkRatio.isFinite && (0 ... 1).contains(highWaterMarkRatio),
            "highWaterMarkRatio must be a finite value in 0...1"
        )
        precondition(
            lowWaterMarkRatio.isFinite && (0 ... 1).contains(lowWaterMarkRatio),
            "lowWaterMarkRatio must be a finite value in 0...1"
        )
        precondition(
            lowWaterMarkRatio <= highWaterMarkRatio,
            "lowWaterMarkRatio must not exceed highWaterMarkRatio"
        )
        self.maxEncodedBytes = maxEncodedBytes
        self.maxDimension = maxDimension
        self.maxPixelCount = maxPixelCount
        self.memoryBudgetBytes = memoryBudgetBytes
        self.diskBudgetBytes = diskBudgetBytes
        self.highWaterMarkRatio = highWaterMarkRatio
        self.lowWaterMarkRatio = lowWaterMarkRatio
    }

    /// Production defaults mandated by the issue: 20 MiB encoded content,
    /// 8192 px per dimension, 32 megapixels total, 64 MiB memory budget,
    /// 512 MiB disk budget, evicting from a 90% high-water mark to 75%.
    static let production = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 64 * 1024 * 1024,
        diskBudgetBytes: 512 * 1024 * 1024
    )

    var highWaterMarkMemoryBytes: Int {
        Self.waterMarkBytes(budget: memoryBudgetBytes, ratio: highWaterMarkRatio)
    }

    var lowWaterMarkMemoryBytes: Int {
        Self.waterMarkBytes(budget: memoryBudgetBytes, ratio: lowWaterMarkRatio)
    }

    var highWaterMarkDiskBytes: Int {
        Self.waterMarkBytes(budget: diskBudgetBytes, ratio: highWaterMarkRatio)
    }

    var lowWaterMarkDiskBytes: Int {
        Self.waterMarkBytes(budget: diskBudgetBytes, ratio: lowWaterMarkRatio)
    }

    /// `Int(Double(budget) * ratio)` alone is unsafe for a `budget` near
    /// `Int.max`: converting a huge `Int` to `Double` itself rounds (every
    /// `Double` this close to `Int.max` is at least 1024 apart from its
    /// neighbors), and can round *up* past `Int.max` even before `ratio`
    /// is applied -- `Double(Int.max)` itself already rounds up to
    /// exactly `2^63`, which traps `Int(_:)` (a precondition failure, not
    /// a silently wrong answer) regardless of `ratio`. Guards against
    /// that by working entirely in `Double` first, only ever converting
    /// back to `Int` once the value is provably representable, and
    /// additionally clamps the result to `budget` itself: since
    /// `ratio` is always in `0...1` (enforced by `init`), a water mark
    /// can never be a meaningful value above its own budget, so any
    /// residual floating-point rounding that pushed the product slightly
    /// past `budget` is clamped back down rather than surfaced.
    private static func waterMarkBytes(budget: Int, ratio: Double) -> Int {
        let product = Double(budget) * ratio
        // `product` finite and strictly below `2^63` (`Double(Int.max)`,
        // itself already rounded up from the true `Int.max`) guarantees
        // `Int(product)` lands on a representable, non-trapping value.
        guard product.isFinite, product < Double(Int.max) else {
            return budget
        }
        return min(Int(product), budget)
    }
}
