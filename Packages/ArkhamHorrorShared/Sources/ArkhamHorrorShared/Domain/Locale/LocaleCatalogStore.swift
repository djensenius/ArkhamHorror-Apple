import Foundation

/// The catalog cache seam.
///
/// Injectable so tests can exercise every read/write, corruption, and eviction path against a
/// scratch directory and a fake clock without ever touching the user's real caches directory
/// or the network.
protocol LocaleCatalogStoring: Sendable {
    /// Returns a fully re-verified snapshot for `identity`, or `nil` when nothing usable is
    /// cached. A cached entry that is corrupt, truncated, stale, or built for a different
    /// manifest is discarded rather than returned in a success shape.
    func load(
        identity: LocaleCatalogIdentity, manifest: LocaleCatalogManifest
    ) async -> LocaleCatalogSnapshot?

    /// Publishes `snapshot` atomically. `manifestBytes` and `chunkBytes` are the *exact*
    /// verified bytes each document arrived as, keyed by digest, so a restored entry can be
    /// re-hashed against the same digests rather than re-serialized from decoded values.
    /// A failure to write is never fatal: the catalog is already in memory, and a cache is an
    /// optimization, never an authority.
    func store(
        snapshot: LocaleCatalogSnapshot, manifestBytes: Data, chunkBytes: [String: Data]
    ) async
    /// Drops every cached entry for `endpoint`, used when a profile's endpoint changes.
    func invalidate(endpoint: String) async
}

/// An injectable monotonic clock, so LRU ordering is deterministic in tests.
protocol LocaleCatalogClock: Sendable {
    var now: Date { get }
}

struct SystemLocaleCatalogClock: LocaleCatalogClock {
    var now: Date {
        Date()
    }
}

/// A bounded, two-tier catalog cache: a small in-memory tier for the snapshots this process is
/// actively rendering from, and a bounded on-disk tier so a relaunch does not re-download a
/// revision it already verified.
///
/// Keyed by the **full** catalog identity — canonical server endpoint, catalog revision,
/// selected locale, and manifest digest — so:
/// - two profiles pointing at one deployment share an entry, and one profile edited to point
///   elsewhere never reads the previous server's catalog;
/// - a revision change writes a *new* entry and the old one is evicted rather than mutated,
///   which is what makes replacement atomic and mixed-revision output impossible;
/// - a locale change is a different entry, so switching languages cannot resolve a title from
///   one locale beside a body from another.
///
/// Every bound is enforced *before* a read or a write, never after: an entry's declared size
/// is checked against the ceiling before its bytes are read, the file count is checked before
/// the directory is enumerated further, and the total on-disk budget is planned before a new
/// entry is published. Replacement uses an atomic swap, and unrelated LRU entries are removed
/// only after the new entry is durably reachable.
actor FileLocaleCatalogStore: LocaleCatalogStoring {
    /// The most snapshots held in memory at once.
    static let maxMemoryEntries = 4
    /// The in-memory snapshot cache budget. A verified snapshot larger than this can still
    /// serve its current caller, but is never retained as an unbounded cache resident.
    static let maxMemoryBytes = 64 * 1024 * 1024
    /// The most entries kept on disk at once.
    static let maxDiskEntries = 8
    /// The total on-disk budget across every entry.
    static let maxDiskBytes = 64 * 1024 * 1024
    /// The most files a single entry directory may contain before it is refused outright.
    static let maxEntryFiles = LocaleCatalogLimits.maxSnapshotChunks + 2

    // Internal rather than private: the on-disk tier lives in `LocaleCatalogStoreDisk.swift`
    // to keep both files under SwiftLint's type-length limit, and Swift's `private` is
    // file-scoped.
    let root: URL
    let clock: any LocaleCatalogClock
    let fileManager: FileManager
    let descriptorTracker: LocaleCatalogDescriptorTracker
    private var memory: [LocaleCatalogIdentity: LocaleCatalogSnapshot] = [:]
    private var memoryOrder: [LocaleCatalogIdentity] = []
    private var memoryBytes: [LocaleCatalogIdentity: Int] = [:]

    /// - Parameters:
    ///   - root: The directory every entry lives under. Tests pass a scratch directory; the
    ///     app passes a subdirectory of its own caches directory.
    ///   - clock: Supplies the access timestamps LRU eviction orders by.
    init(
        root: URL,
        clock: any LocaleCatalogClock = SystemLocaleCatalogClock(),
        fileManager: FileManager = .default,
        descriptorTracker: LocaleCatalogDescriptorTracker = LocaleCatalogDescriptorTracker()
    ) {
        self.root = root
        self.clock = clock
        self.fileManager = fileManager
        self.descriptorTracker = descriptorTracker
    }

    /// The app's own catalog cache directory, or `nil` when no caches directory is available.
    static func defaultRoot(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "LocaleCatalog", directoryHint: .isDirectory)
    }

    func load(
        identity: LocaleCatalogIdentity, manifest: LocaleCatalogManifest
    ) async -> LocaleCatalogSnapshot? {
        LocaleCatalogPOSIX.$tracker.withValue(descriptorTracker) { () -> LocaleCatalogSnapshot? in
            if let cached = memory[identity] {
                touchMemory(identity)
                return cached
            }
            guard let snapshot = readFromDisk(identity: identity, manifest: manifest) else {
                discardDiskEntry(identity)
                return nil
            }
            insertMemory(identity, snapshot)
            return snapshot
        }
    }

    func store(
        snapshot: LocaleCatalogSnapshot, manifestBytes: Data, chunkBytes: [String: Data]
    ) async {
        insertMemory(snapshot.identity, snapshot)
        LocaleCatalogPOSIX.$tracker.withValue(descriptorTracker) {
            writeToDisk(
                snapshot: snapshot, manifestBytes: manifestBytes, chunkBytes: chunkBytes
            )
        }
    }

    func invalidate(endpoint: String) async {
        let matching = memory.keys.filter { $0.endpoint == endpoint }
        for identity in matching {
            removeMemory(identity)
        }
        LocaleCatalogPOSIX.$tracker.withValue(descriptorTracker) {
            for entry in diskEntries() where entry.endpoint == endpoint {
                if let identity = entry.identity {
                    discardDiskEntry(identity)
                }
            }
        }
    }

    // MARK: - Memory tier

    private func touchMemory(_ identity: LocaleCatalogIdentity) {
        memoryOrder.removeAll { $0 == identity }
        memoryOrder.append(identity)
    }

    private func insertMemory(
        _ identity: LocaleCatalogIdentity, _ snapshot: LocaleCatalogSnapshot
    ) {
        let byteCount = snapshotByteCount(snapshot)
        removeMemory(identity)
        guard byteCount <= Self.maxMemoryBytes else { return }
        while shouldEvictMemory(for: byteCount) {
            guard let leastRecent = memoryOrder.first else { break }
            removeMemory(leastRecent)
        }
        memory[identity] = snapshot
        memoryBytes[identity] = byteCount
        touchMemory(identity)
    }

    private func removeMemory(_ identity: LocaleCatalogIdentity) {
        memory[identity] = nil
        memoryBytes[identity] = nil
        memoryOrder.removeAll { $0 == identity }
    }

    private func shouldEvictMemory(for byteCount: Int) -> Bool {
        memoryOrder.count >= Self.maxMemoryEntries
            || memoryBytes.values.reduce(0, +) + byteCount > Self.maxMemoryBytes
    }

    private func snapshotByteCount(_ snapshot: LocaleCatalogSnapshot) -> Int {
        snapshot.localeChain.reduce(into: 0) { total, locale in
            guard let record = snapshot.manifest.record(for: locale) else { return }
            total += record.bytes
        }
    }
}
