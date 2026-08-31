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
    /// Maximum number of durable per-key authority-record files
    /// (`<hash>.applied`, see `AssetDiskCache+Disposition.swift`) this
    /// cache may keep on disk at once.
    ///
    /// **Why a *count* budget in addition to ``diskBudgetBytes``.** One
    /// such record is durably written for every key that is ever
    /// *issued*, including keys that never publish a single byte (a
    /// transport failure, a definitive 404, a cancelled fetch). A
    /// workload made of many distinct, never-republished keys therefore
    /// accumulates arbitrarily many tiny files whose *bytes* barely move
    /// the byte budget at all, while their sheer *count* is a genuine
    /// resource-exhaustion vector: inode/metadata overhead, and — since
    /// every single issuance now proves the budget with a full directory
    /// listing — an ever-growing per-issuance cost. Bounding the count
    /// directly is what makes that cost bounded; reclaim is described on
    /// ``AssetDiskCache/reconciledAuthorityRecordNames(_:)``.
    ///
    /// See ``AssetCacheLimits/production`` for the reasoning behind the
    /// production default.
    let maxAuthorityRecordCount: Int
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
        maxAuthorityRecordCount: Int = 20000,
        highWaterMarkRatio: Double = 0.90,
        lowWaterMarkRatio: Double = 0.75
    ) {
        precondition(maxEncodedBytes >= 0, "maxEncodedBytes must not be negative")
        precondition(maxDimension >= 0, "maxDimension must not be negative")
        precondition(maxPixelCount >= 0, "maxPixelCount must not be negative")
        precondition(memoryBudgetBytes >= 0, "memoryBudgetBytes must not be negative")
        precondition(diskBudgetBytes >= 0, "diskBudgetBytes must not be negative")
        precondition(
            maxAuthorityRecordCount >= 0,
            "maxAuthorityRecordCount must not be negative"
        )
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
        self.maxAuthorityRecordCount = maxAuthorityRecordCount
        self.highWaterMarkRatio = highWaterMarkRatio
        self.lowWaterMarkRatio = lowWaterMarkRatio
    }

    /// Production defaults mandated by the issue: 20 MiB encoded content,
    /// 8192 px per dimension, 32 megapixels total, 64 MiB memory budget,
    /// 512 MiB disk budget, evicting from a 90% high-water mark to 75%.
    ///
    /// ``maxAuthorityRecordCount`` is `20_000`, chosen against the disk
    /// byte budget rather than picked arbitrarily. The count cap's one
    /// genuinely dangerous failure mode is firing on a *legitimate*
    /// cache: authority records for keys that are currently live
    /// (`.content`/`.retiring`) can never be reclaimed, so if the live
    /// count alone could exceed the high-water mark, an ordinary
    /// byte-budget-full cache would durably disable its own writes. A
    /// cache that is exactly full at 512 MiB with 20,000 live entries
    /// implies an average asset of about 26 KiB; every real asset this
    /// app caches (card art and card backs, encoded AVIF/JPEG at display
    /// resolution) is comfortably larger than that, so the byte budget
    /// is always the binding constraint first and this cap can only be
    /// reached by *issuance* churn over keys that never publish
    /// anything — exactly the workload it exists to bound. It is also
    /// small enough to keep the O(entries) directory pass every issuance
    /// performs bounded (tens of thousands of entries, not millions)
    /// instead of growing without limit.
    static let production = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 64 * 1024 * 1024,
        diskBudgetBytes: 512 * 1024 * 1024,
        maxAuthorityRecordCount: 20000
    )

    var highWaterMarkMemoryBytes: Int {
        Self.waterMark(budget: memoryBudgetBytes, ratio: highWaterMarkRatio)
    }

    var lowWaterMarkMemoryBytes: Int {
        Self.waterMark(budget: memoryBudgetBytes, ratio: lowWaterMarkRatio)
    }

    var highWaterMarkDiskBytes: Int {
        Self.waterMark(budget: diskBudgetBytes, ratio: highWaterMarkRatio)
    }

    var lowWaterMarkDiskBytes: Int {
        Self.waterMark(budget: diskBudgetBytes, ratio: lowWaterMarkRatio)
    }

    /// Authority-record reclaim begins once the number of `<hash>.applied`
    /// files reaches this mark — the exact analogue of
    /// ``highWaterMarkDiskBytes`` for ``maxAuthorityRecordCount``, using
    /// the same ratios and the same overflow-safe conversion.
    var highWaterMarkAuthorityRecordCount: Int {
        Self.waterMark(budget: maxAuthorityRecordCount, ratio: highWaterMarkRatio)
    }

    /// Authority-record reclaim (oldest-revision-first among the records
    /// that are safe to reclaim) continues until the count falls to this
    /// mark — the exact analogue of ``lowWaterMarkDiskBytes``.
    var lowWaterMarkAuthorityRecordCount: Int {
        Self.waterMark(budget: maxAuthorityRecordCount, ratio: lowWaterMarkRatio)
    }

    /// The smallest number of accounted bytes any single *content* entry
    /// can ever contribute — a deliberately conservative lower bound on
    /// one ``AssetCacheMetadata`` sidecar's serialized JSON (two 64-hex
    /// digests, a 32-hex authority identifier, an ISO-8601 date, a
    /// fixed-width access sequence, and every field name, all of which
    /// together already exceed this before any payload byte is counted).
    /// Used only to derive ``maxAccountableDirectoryEntryCount`` below;
    /// under-estimating here is the safe direction, since it only makes
    /// that ceiling more generous.
    static let minimumAccountedContentEntryBytes = 256

    /// The largest number of directory entries this cache's *own*
    /// accounting could ever legitimately produce, with a factor-of-two
    /// headroom on top. A listing larger than this cannot be explained by
    /// any combination of budgets configured here, so
    /// ``AssetDiskCache/evictIfNeeded()`` treats it as an unaccountable
    /// flood and fails closed *immediately*, before attempting the
    /// per-entry decode/stat pass that would otherwise make one call's
    /// cost grow without bound.
    ///
    /// Derived, never guessed: at most ``maxAuthorityRecordCount``
    /// `.applied` files, plus at most two names (a payload plus its
    /// metadata sidecar) per content entry that ``diskBudgetBytes`` could
    /// hold at ``minimumAccountedContentEntryBytes`` each, plus a small
    /// fixed allowance for this cache's reserved files (lock, clear
    /// epoch, access sequence, freshness witness, disabled-writes marker)
    /// and any in-flight `.tmp` files. Doubling the total is what keeps
    /// an entirely legitimate, completely full cache from ever tripping
    /// it. Saturates rather than overflowing for absurd configured
    /// budgets.
    var maxAccountableDirectoryEntryCount: Int {
        let maxContentEntries = diskBudgetBytes / Self.minimumAccountedContentEntryBytes
        let reservedNameAllowance = 64
        return Self.saturatingProduct(
            2,
            Self.saturatingSum([
                maxAuthorityRecordCount,
                Self.saturatingProduct(2, maxContentEntries),
                reservedNameAllowance,
            ])
        )
    }

    private static func saturatingProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        return overflowed ? Int.max : product
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflowed) = partial.addingReportingOverflow(value)
            return overflowed ? Int.max : sum
        }
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
    private static func waterMark(budget: Int, ratio: Double) -> Int {
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
