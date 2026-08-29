import Foundation

/// The encoder `LosslessJSONKeyedEncodingContainer.superEncoder()`/`superEncoder(forKey:)`
/// and `LosslessJSONUnkeyedEncodingContainer.superEncoder()` return.
///
/// A bare ``LosslessJSONValueEncoder`` only ever writes to its own private `node` — nothing
/// reads that back into the *parent* container that vended it, so anything a caller encodes
/// through a plain `superEncoder()`/`superEncoder(forKey:)` result would otherwise be
/// silently discarded from the final JSON. This subclass instead remembers where it was
/// vended from and, in `deinit` (mirroring Foundation's own `JSONEncoder` referencing-encoder
/// pattern — by the time the encoder is deallocated, the caller is done encoding through it),
/// writes its final `node` back into that location.
final class LosslessJSONReferencingEncoder: LosslessJSONValueEncoder {
    private enum Destination {
        case keyed(ObjectBox, String)
        case unkeyed(ArrayBox, Int)
    }

    private let destination: Destination

    /// For `superEncoder()`/`superEncoder(forKey:)` on a keyed container: writes back into
    /// `box.entries[key]`, overwriting any existing entry at that key exactly like every
    /// other keyed `encode(_:forKey:)` overload does.
    init(keyedInto box: ObjectBox, key: String, codingPath: [CodingKey]) {
        destination = .keyed(box, key)
        super.init(codingPath: codingPath)
    }

    /// For `superEncoder()` on an unkeyed container: `index` must already have a placeholder
    /// reserved in `box.elements` (so later sibling `encode(_:)` calls get correct indices
    /// regardless of when this encoder is actually deallocated); writes back into that slot.
    init(unkeyedInto box: ArrayBox, index: Int, codingPath: [CodingKey]) {
        destination = .unkeyed(box, index)
        super.init(codingPath: codingPath)
    }

    deinit {
        switch destination {
        case let .keyed(box, key):
            box.entries[key] = node
        case let .unkeyed(box, index):
            guard box.elements.indices.contains(index) else { return }
            box.elements[index] = node
        }
    }
}
