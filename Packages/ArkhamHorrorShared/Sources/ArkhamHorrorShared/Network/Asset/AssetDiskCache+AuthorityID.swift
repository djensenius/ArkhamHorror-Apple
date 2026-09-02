import Foundation
import Security

/// A per-operation, cryptographically-random 128-bit **authority
/// identifier** — the unit of durable write authority for one key in
/// ``AssetDiskCache``, replacing the monotonically-increasing integer
/// "ticket" a prior revision of this cache issued from a shared counter.
///
/// **Why a random ID rather than a counter.** A counter's authority is
/// only ever as trustworthy as the durable state that remembers how far
/// it has counted. If that state is ever lost, reset, or rolled back —
/// by an I/O fault, external interference, or a partially-failed
/// whole-cache clear — a fresh reservation can hand out a value some
/// still-in-flight operation issued long ago is legitimately still
/// holding, and that operation's compare-and-swap then wrongly succeeds
/// against state it no longer owns. Every layer a prior revision added
/// to defend a counter (a second mirror copy of the record, a per-key
/// issuance "anchor" witness, a root-level non-replayable per-key usage
/// floor index, and a directory-global monotonic ticket sequence) existed
/// solely to make that reconstruction detectable. A 128-bit CSPRNG value
/// needs none of them: a freshly minted ID cannot collide with an ID any
/// other operation — in this process, a sibling process, or this same
/// directory's entire past — might still be holding, with probability
/// `2^-128`, *regardless* of what durable state was lost beforehand.
/// Losing the record therefore stops being ambiguous: the next issuance
/// simply mints a value nothing else can match, so the entire
/// floor/anchor/mirror/global-sequence apparatus is deleted rather than
/// patched.
///
/// Encoded in JSON as exactly 32 lowercase hexadecimal characters — a
/// compact, unambiguous, fixed-length form validated on decode with the
/// same shape check ``AssetDiskCache/isValidContentHash(_:)`` applies to
/// payload digests, so a tampered or truncated on-disk record can never
/// decode into a short, low-entropy, or otherwise guessable ID.
struct AuthorityID: Sendable, Equatable, Hashable, Codable {
    /// 128 bits: the same width every other collision-resistance
    /// argument in this package (content digests aside) is stated
    /// against, and far past the point where birthday collisions across
    /// this cache's entire realistic lifetime are worth modelling.
    static let byteCount = 16

    let bytes: Data

    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    /// The reserved all-zero identifier carried by
    /// ``AssetDiskCache/KeyAuthorityRecord/pristine``.
    ///
    /// **Deliberately not a distinct "sentinel" case in the type.** It is
    /// simply an ordinary `AuthorityID` whose bytes are all zero, which
    /// ``random()`` can never realistically produce (probability
    /// `2^-128`), so it can be compared, encoded, and validated exactly
    /// like any other value while still letting the record-level
    /// invariant `transitionRevision == 0 <=> record == .pristine` be
    /// asserted structurally.
    static let pristine = AuthorityID(
        unchecked: Data(repeating: 0, count: AuthorityID.byteCount)
    )

    /// Mints a brand-new identifier from the platform CSPRNG.
    ///
    /// Deliberately policy-free: it draws bytes and nothing else. Every
    /// rule about which drawn values are *usable* as a fresh authority --
    /// rejecting the reserved ``pristine`` sentinel, and rejecting a
    /// value equal to either identifier a key's record already names --
    /// is enforced one layer up, in
    /// ``AssetDiskCache/mintFreshAuthorityIDLocked(distinctFrom:)``,
    /// which is the only place with the durable record in hand to compare
    /// against and the only place that can bound its own retries.
    ///
    /// Fails closed with a typed
    /// ``AssetError/cachePersistenceFailed(_:)`` — never a force-unwrap,
    /// never a fallback to a weaker source of randomness, and never a
    /// crash — if `SecRandomCopyBytes` reports any non-success status:
    /// an operation that cannot prove it holds a unique authority must
    /// not be issued at all.
    static func random() throws -> AuthorityID {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        guard status == errSecSuccess else {
            throw AssetError.cachePersistenceFailed(
                "Could not generate a random cache authority identifier (status \(status));" +
                    " refusing to issue an operation without a unique durable authority."
            )
        }
        return AuthorityID(unchecked: Data(bytes))
    }

    /// The canonical, fixed-length, lowercase-hex encoding of this
    /// identifier — exactly `2 * byteCount` characters.
    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `nil` unless `value` is exactly `2 * byteCount` lowercase ASCII
    /// hex characters — the sole shape this type ever accepts from
    /// otherwise-untrusted on-disk JSON.
    init?(hexString value: String) {
        let utf8 = Array(value.utf8)
        guard utf8.count == AuthorityID.byteCount * 2 else { return nil }
        var bytes = Data(capacity: AuthorityID.byteCount)
        var index = 0
        while index < utf8.count {
            guard
                let high = AuthorityID.hexDigitValue(utf8[index]),
                let low = AuthorityID.hexDigitValue(utf8[index + 1])
            else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(unchecked: bytes)
    }

    /// Lowercase-only on purpose: accepting uppercase (or mixed) hex
    /// would give one identifier two distinct encodings, so two records
    /// that are byte-for-byte different could still decode equal — an
    /// ambiguity a compare-and-swap keyed on exact equality must never
    /// have to reason about.
    private static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x61 ... 0x66: byte - 0x61 + 10
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let decoded = AuthorityID(hexString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Authority identifier is not 32 lowercase hex characters"
            )
        }
        self = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
