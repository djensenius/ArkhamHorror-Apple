import Foundation

/// A monotonically increasing LRU sequence value, encoded as a fixed-width
/// (zero-padded, 19-decimal-digit) string — never a variable-width JSON
/// integer — so every ``AssetCacheMetadata`` value's serialized byte size
/// stays exactly the same width regardless of the specific sequence value
/// it currently holds. `AssetMemoryCache`'s per-entry accounted-byte-count
/// is measured once at construction and never re-measured on every
/// subsequent touch (see `CachedAsset.accountedByteCount`'s doc comment);
/// that optimization is only correct because this type's *serialized*
/// footprint can never change after construction, no matter how many times
/// the underlying integer is later reassigned — exactly the same
/// fixed-width property the prior `Date`/`.iso8601` field relied on, that
/// this type must preserve now that it carries a value which otherwise
/// varies in decimal-digit width.
struct AssetAccessSequence: Codable, Sendable, Equatable, Comparable, CustomStringConvertible {
    /// Always `0 ... Int.max`; ``AssetAccessSequenceAllocator`` never
    /// allocates a negative value.
    let value: Int

    static let digitWidth = 19

    init(_ value: Int) {
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    var description: String {
        let raw = String(value)
        let padCount = max(0, Self.digitWidth - raw.count)
        return String(repeating: "0", count: padCount) + raw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard string.utf8.count == Self.digitWidth,
              string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let parsed = Int(string)
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Access sequence is not a fixed-width, non-negative integer"
            )
        }
        value = parsed
    }
}

/// A single, monotonically increasing `Int` counter used to stamp
/// ``AssetCacheMetadata/accessSequence`` — one instance owned privately by
/// each cache layer (``AssetMemoryCache``, ``AssetDiskCache``) that needs
/// its own independent LRU ordering; never shared across layers, and never
/// itself `Sendable`/actor-isolated on its own, since each owning actor
/// already serializes every call into it.
struct AssetAccessSequenceAllocator {
    private(set) var next: Int

    /// Starts allocating from `resumingAfter + 1` (or `0` if `nil`), so a
    /// disk cache recovering at startup can resume strictly after the
    /// highest sequence value found among its own currently valid
    /// persisted entries, guaranteeing every freshly allocated value is
    /// greater than every value that already exists on disk.
    init(resumingAfter highestKnownValue: Int? = nil) {
        next = highestKnownValue.map { $0 == Int.max ? Int.max : $0 + 1 } ?? 0
    }

    /// Returns the next sequence value and advances the counter. Once
    /// `Int.max` is reached, this deliberately saturates rather than
    /// wrapping to a negative value (which would corrupt ordering by
    /// making a freshly touched entry sort as older than one touched long
    /// ago): every subsequent call also returns `Int.max`. A real
    /// migration to a fresh sequence space this many operations later is
    /// out of scope — reaching this bound requires processing more cache
    /// operations than is physically achievable — but returning a defined,
    /// still-monotonic-or-equal value here (rather than trapping or
    /// silently wrapping) keeps the cache itself crash-free and keeps
    /// ordering *among saturated entries* well-defined too: callers that
    /// need a deterministic order even among ties at the saturation
    /// bound fall back to comparing the cache key itself (see
    /// ``AssetDiskCache/Entry`` eviction sort).
    mutating func allocate() -> AssetAccessSequence {
        guard next < Int.max else { return AssetAccessSequence(Int.max) }
        defer {
            let (incremented, overflowed) = next.addingReportingOverflow(1)
            next = overflowed ? Int.max : incremented
        }
        return AssetAccessSequence(next)
    }
}
