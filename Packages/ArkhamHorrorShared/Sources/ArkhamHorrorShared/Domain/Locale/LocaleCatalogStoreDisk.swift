import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

extension FileLocaleCatalogStore {
    private static let entryRecordName = "entry.json"
    private static let entryRecordStagingName = "entry-update.json"
    /// The temporary name a deferred chunk is written under before its atomic rename.
    private static let chunkStagingName = "chunk-update.json"

    struct DiskEntry: Sendable, Equatable {
        let endpoint: String
        let catalogRevision: String
        let locale: String
        let manifestSha256: String
        let accessedAt: Date
        let name: String
        let byteCount: Int

        var identity: LocaleCatalogIdentity? {
            guard let url = URL(string: endpoint) else { return nil }
            return LocaleCatalogIdentity(
                endpoint: url,
                catalogRevision: catalogRevision,
                locale: locale,
                manifestSha256: manifestSha256
            )
        }
    }

    private struct DiskScan {
        var entries: [DiskEntry]
        var occupiedBytes: Int
    }

    static func directoryName(for identity: LocaleCatalogIdentity) -> String {
        let joined = [
            identity.endpoint, identity.catalogRevision,
            identity.locale, identity.manifestSha256,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entryURL(for identity: LocaleCatalogIdentity) -> URL {
        root.appending(
            path: Self.directoryName(for: identity), directoryHint: .isDirectory
        )
    }

    func readFromDisk(
        identity: LocaleCatalogIdentity, manifest: LocaleCatalogManifest
    ) -> LocaleCatalogSnapshot? {
        guard let rootFD = LocaleCatalogPOSIX.openDirectory(path: root.path()) else {
            return nil
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        guard let directoryFD = LocaleCatalogPOSIX.openDirectory(
            parent: rootFD, name: Self.directoryName(for: identity)
        ) else {
            return nil
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        guard removeStagingFiles(directoryFD: directoryFD) else { return nil }
        guard let record = readEntryRecord(rootFD: rootFD, name: Self.directoryName(for: identity)),
              record.identity == identity,
              let manifestBytes = LocaleCatalogPOSIX.readRegular(
                  parent: directoryFD,
                  name: "manifest.json",
                  maxBytes: LocaleCatalogLimits.maxManifestBytes
              ),
              LocaleCatalogLoader.sha256Hex(manifestBytes) == identity.manifestSha256
        else {
            return nil
        }
        // Only the eager packs are required, so an entry written before deferred packs
        // existed (which also holds the `cardNames` files) still loads as is; those files are
        // picked up by `readDeferredFromDisk` on first need.
        guard let locations = manifest.chunkLocations(chainFrom: identity.locale) else {
            return nil
        }
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        for location in locations where !location.isDeferred {
            guard chunks.count < LocaleCatalogLimits.maxSnapshotChunks,
                  let chunk = readChunk(
                      directoryFD: directoryFD,
                      descriptor: location.descriptor,
                      locale: location.locale,
                      fallback: location.fallback
                  )
            else {
                return nil
            }
            chunks[location.key] = chunk
        }
        // The cached manifest is the digest-verified one, so its size is exact; this is how
        // an entry written before the size was tracked still budgets deferred packs.
        let snapshot = LocaleCatalogSnapshot(
            identity: identity, manifest: manifest, chunks: chunks,
            manifestByteCount: manifestBytes.count
        )
        guard snapshot.isComplete else { return nil }
        _ = writeEntryRecord(identity: identity, rootFD: rootFD, entryName: record.name)
        return snapshot
    }

    private func readChunk(
        directoryFD: Int32,
        descriptor: LocaleCatalogChunkDescriptor,
        locale: String,
        fallback: String?
    ) -> LocaleCatalogChunk? {
        guard let bytes = LocaleCatalogPOSIX.readRegular(
            parent: directoryFD,
            name: "\(descriptor.sha256).json",
            maxBytes: min(descriptor.bytes, LocaleCatalogLimits.maxChunkBytes)
        ), bytes.count == descriptor.bytes,
        LocaleCatalogLoader.sha256Hex(bytes) == descriptor.sha256,
        let value = try? LosslessJSONParser.parse(
            bytes, maxByteCount: LocaleCatalogLimits.maxChunkBytes
        )
        else {
            return nil
        }
        guard case let .success(chunk) = LocaleCatalogChunk.validate(
            value,
            expectedLocale: locale,
            expectedFallback: fallback,
            expectedPack: descriptor.pack,
            expectedKeys: descriptor.keys,
            expectedUnsupportedKeys: descriptor.unsupportedKeys
        ) else {
            return nil
        }
        return chunk
    }

    func diskEntries() -> [DiskEntry] {
        guard let rootFD = LocaleCatalogPOSIX.openDirectory(path: root.path()) else {
            return []
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        return scanRoot(rootFD)?.entries ?? []
    }

    private func scanRoot(_ rootFD: Int32) -> DiskScan? {
        guard let names = LocaleCatalogPOSIX.names(
            in: rootFD, limit: Self.maxDiskEntries + 1
        ) else {
            return nil
        }
        var scan = DiskScan(entries: [], occupiedBytes: 0)
        for name in names {
            guard isEntryName(name) else {
                guard LocaleCatalogPOSIX.remove(parent: rootFD, name: name) else {
                    return nil
                }
                continue
            }
            guard let entry = scannedEntry(rootFD: rootFD, name: name) else {
                guard LocaleCatalogPOSIX.remove(parent: rootFD, name: name) else {
                    return nil
                }
                continue
            }
            let size = entry.byteCount
            let nextBytes = scan.occupiedBytes.addingReportingOverflow(size)
            guard !nextBytes.overflow else { return nil }
            scan.occupiedBytes = nextBytes.partialValue
            scan.entries.append(entry)
        }
        return pruneScan(scan, rootFD: rootFD)
    }

    private func scannedEntry(rootFD: Int32, name: String) -> DiskEntry? {
        guard removeStaleEntryRecordStaging(rootFD: rootFD, entryName: name),
              let size = LocaleCatalogPOSIX.directorySize(
                  parent: rootFD, name: name, fileLimit: Self.maxEntryFiles
              )
        else {
            return nil
        }
        return readEntryRecord(rootFD: rootFD, name: name, byteCount: size)
    }

    private func removeStaleEntryRecordStaging(rootFD: Int32, entryName: String) -> Bool {
        guard let directoryFD = LocaleCatalogPOSIX.openDirectory(
            parent: rootFD, name: entryName
        ) else {
            return false
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        return removeStagingFiles(directoryFD: directoryFD)
    }

    /// Removes an interrupted entry-record or deferred-chunk write.
    private func removeStagingFiles(directoryFD: Int32) -> Bool {
        LocaleCatalogPOSIX.removeIfPresent(
            parent: directoryFD, name: Self.entryRecordStagingName
        ) && LocaleCatalogPOSIX.removeIfPresent(
            parent: directoryFD, name: Self.chunkStagingName
        )
    }

    private func pruneScan(_ initialScan: DiskScan, rootFD: Int32) -> DiskScan? {
        var scan = initialScan
        var oldestFirst = scan.entries.sorted {
            ($0.accessedAt, $0.name) < ($1.accessedAt, $1.name)
        }
        var evictedNames: Set<String> = []
        while needsDiskEviction(
            occupiedBytes: scan.occupiedBytes,
            reserving: 0,
            entryCount: scan.entries.count - evictedNames.count
        ) {
            guard let oldest = oldestFirst.first else { return nil }
            oldestFirst.removeFirst()
            guard LocaleCatalogPOSIX.remove(parent: rootFD, name: oldest.name) else {
                return nil
            }
            evictedNames.insert(oldest.name)
            scan.occupiedBytes -= oldest.byteCount
        }
        scan.entries.removeAll { evictedNames.contains($0.name) }
        if !evictedNames.isEmpty, !LocaleCatalogPOSIX.syncDirectory(rootFD) {
            return nil
        }
        return scan
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func writeToDisk(
        snapshot: LocaleCatalogSnapshot, manifestBytes: Data, chunkBytes: [String: Data]
    ) {
        guard let rootFD = LocaleCatalogPOSIX.openOrCreateDirectory(path: root.path()) else {
            return
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        guard let scan = scanRoot(rootFD) else {
            return
        }
        guard let payloadBytes = payloadByteCount(
            snapshot: snapshot, manifestBytes: manifestBytes, chunkBytes: chunkBytes
        ), payloadBytes <= Self.maxDiskBytes else {
            return
        }

        let stagingName = "staging-\(UUID().uuidString)"
        guard LocaleCatalogPOSIX.makeDirectory(parent: rootFD, name: stagingName) else {
            return
        }
        guard let stagingFD = LocaleCatalogPOSIX.openDirectory(parent: rootFD, name: stagingName)
        else {
            _ = LocaleCatalogPOSIX.remove(parent: rootFD, name: stagingName)
            return
        }
        defer {
            LocaleCatalogPOSIX.closeDescriptor(stagingFD)
            _ = LocaleCatalogPOSIX.remove(parent: rootFD, name: stagingName)
        }
        guard LocaleCatalogPOSIX.writeRegular(
            manifestBytes, parent: stagingFD, name: "manifest.json"
        ) else {
            return
        }
        for location in Self.uniqueByDigest(snapshot.heldChunkLocations) {
            let digest = location.descriptor.sha256
            guard let bytes = chunkBytes[digest],
                  LocaleCatalogPOSIX.writeRegular(bytes, parent: stagingFD, name: "\(digest).json")
            else {
                return
            }
        }
        guard writeEntryRecord(
            identity: snapshot.identity, directoryFD: stagingFD
        ), LocaleCatalogPOSIX.syncDirectory(stagingFD) else {
            return
        }
        let destination = Self.directoryName(for: snapshot.identity)
        guard let evictions = plannedEvictions(
            scan: scan, destination: destination, reserving: payloadBytes
        ) else {
            return
        }
        let existingDestination = scan.entries.first { $0.name == destination }
        let published: Bool = if existingDestination == nil {
            LocaleCatalogPOSIX.moveExclusive(
                parent: rootFD, from: stagingName, to: destination
            )
        } else {
            LocaleCatalogPOSIX.swap(
                parent: rootFD, first: stagingName, second: destination
            )
        }
        guard published else {
            return
        }
        guard LocaleCatalogPOSIX.syncDirectory(rootFD) else { return }
        for entry in evictions {
            guard LocaleCatalogPOSIX.remove(parent: rootFD, name: entry.name) else {
                return
            }
        }
        _ = LocaleCatalogPOSIX.removeIfPresent(parent: rootFD, name: stagingName)
        _ = LocaleCatalogPOSIX.syncDirectory(rootFD)
    }

    /// `snapshot` plus every pending deferred chunk read from its own entry directory, each
    /// re-hashed and re-validated, or `nil` when the entry or any chunk is missing or bad.
    func readDeferredFromDisk(snapshot: LocaleCatalogSnapshot) -> LocaleCatalogSnapshot? {
        let identity = snapshot.identity
        let entryName = Self.directoryName(for: identity)
        guard let rootFD = LocaleCatalogPOSIX.openDirectory(path: root.path()) else {
            return nil
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        guard let record = readEntryRecord(rootFD: rootFD, name: entryName),
              record.identity == identity,
              let directoryFD = LocaleCatalogPOSIX.openDirectory(parent: rootFD, name: entryName)
        else {
            return nil
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        for location in snapshot.pendingDeferredChunks {
            guard let chunk = readChunk(
                directoryFD: directoryFD,
                descriptor: location.descriptor,
                locale: location.locale,
                fallback: location.fallback
            ) else {
                return nil
            }
            chunks[location.key] = chunk
        }
        return snapshot.adding(chunks: chunks)
    }

    /// Adds `snapshot`'s deferred chunks to its existing entry directory. Each file is written
    /// under a temporary name and renamed into place, so a reader sees either no file or the
    /// whole verified one. The bytes count against the same disk budget, evicting other
    /// entries least-recently-used first; when they cannot fit nothing is written.
    ///
    /// Only the entry's net growth is reserved: a corrupt file being repaired is replaced, so
    /// its current size is subtracted. The planned evictions run *before* any write, so the
    /// entry's final size already fits and the cache cannot end above budget even if a write
    /// then fails. On a failed write or directory sync every file this call published is
    /// removed again, leaving the entry no larger than it was (a replaced corrupt file is
    /// removed rather than restored, which only shrinks it).
    func writeDeferredToDisk(snapshot: LocaleCatalogSnapshot, chunkBytes: [String: Data]) {
        let identity = snapshot.identity
        let entryName = Self.directoryName(for: identity)
        guard let rootFD = LocaleCatalogPOSIX.openDirectory(path: root.path()) else { return }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        guard let scan = scanRoot(rootFD),
              let existing = scan.entries.first(where: { $0.name == entryName }),
              existing.identity == identity,
              let directoryFD = LocaleCatalogPOSIX.openDirectory(parent: rootFD, name: entryName)
        else {
            return
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        guard let files = deferredFilesToWrite(
            snapshot: snapshot, chunkBytes: chunkBytes, directoryFD: directoryFD
        ), !files.isEmpty,
        let evictions = plannedEvictions(
            scan: scan,
            destination: entryName,
            reserving: max(
                existing.byteCount + files.reduce(0) { $0 + $1.bytes.count - $1.replacedBytes },
                0
            )
        ) else {
            return
        }
        for entry in evictions {
            guard LocaleCatalogPOSIX.remove(parent: rootFD, name: entry.name) else { return }
        }
        var published: [String] = []
        for file in files {
            guard writeAtomically(file.bytes, directoryFD: directoryFD, name: file.name) else {
                removePublished(published, directoryFD: directoryFD, rootFD: rootFD)
                return
            }
            published.append(file.name)
        }
        guard LocaleCatalogPOSIX.syncDirectory(directoryFD) else {
            removePublished(published, directoryFD: directoryFD, rootFD: rootFD)
            return
        }
        _ = writeEntryRecord(identity: identity, rootFD: rootFD, entryName: entryName)
        _ = LocaleCatalogPOSIX.syncDirectory(rootFD)
    }

    /// Rolls back a failed deferred write: removes the files it published, best effort.
    private func removePublished(_ names: [String], directoryFD: Int32, rootFD: Int32) {
        for name in names {
            _ = LocaleCatalogPOSIX.removeIfPresent(parent: directoryFD, name: name)
        }
        _ = LocaleCatalogPOSIX.syncDirectory(directoryFD)
        _ = LocaleCatalogPOSIX.syncDirectory(rootFD)
    }

    /// The deferred chunk files `snapshot` holds that the entry lacks or holds corrupted, with
    /// the on-disk size of the file each replaces (`0` when absent), or `nil` when any supplied
    /// bytes do not match their descriptor.
    private func deferredFilesToWrite(
        snapshot: LocaleCatalogSnapshot, chunkBytes: [String: Data], directoryFD: Int32
    ) -> [DeferredFile]? {
        var files: [DeferredFile] = []
        for location in Self.uniqueByDigest(snapshot.heldChunkLocations.filter(\.isDeferred)) {
            let descriptor = location.descriptor
            let name = "\(descriptor.sha256).json"
            guard let bytes = chunkBytes[descriptor.sha256],
                  bytes.count == descriptor.bytes,
                  LocaleCatalogLoader.sha256Hex(bytes) == descriptor.sha256
            else {
                return nil
            }
            let present = LocaleCatalogPOSIX.readRegular(
                parent: directoryFD, name: name, maxBytes: descriptor.bytes
            )
            if let present, LocaleCatalogLoader.sha256Hex(present) == descriptor.sha256 {
                continue
            }
            let replacedBytes = LocaleCatalogPOSIX.regularFileSize(
                parent: directoryFD, name: name
            ) ?? 0
            files.append(DeferredFile(name: name, bytes: bytes, replacedBytes: replacedBytes))
        }
        return files
    }

    /// A deferred chunk file to publish, and the on-disk size of the file it replaces.
    private struct DeferredFile {
        let name: String
        let bytes: Data
        let replacedBytes: Int
    }

    private func writeAtomically(_ bytes: Data, directoryFD: Int32, name: String) -> Bool {
        let written = LocaleCatalogPOSIX.removeIfPresent(
            parent: directoryFD, name: Self.chunkStagingName
        ) && LocaleCatalogPOSIX.writeRegular(
            bytes, parent: directoryFD, name: Self.chunkStagingName
        ) && LocaleCatalogPOSIX.replace(
            parent: directoryFD, from: Self.chunkStagingName, to: name
        )
        if !written {
            _ = LocaleCatalogPOSIX.removeIfPresent(parent: directoryFD, name: Self.chunkStagingName)
        }
        return written
    }

    private static func uniqueByDigest(
        _ locations: [LocaleCatalogChunkLocation]
    ) -> [LocaleCatalogChunkLocation] {
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.descriptor.sha256).inserted }
    }

    private func payloadByteCount(
        snapshot: LocaleCatalogSnapshot,
        manifestBytes: Data,
        chunkBytes: [String: Data]
    ) -> Int? {
        var total = manifestBytes.count
        guard snapshot.chainChunkLocations != nil else { return nil }
        for location in Self.uniqueByDigest(snapshot.heldChunkLocations) {
            guard let bytes = chunkBytes[location.descriptor.sha256],
                  bytes.count == location.descriptor.bytes
            else {
                return nil
            }
            let next = total.addingReportingOverflow(bytes.count)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    private func plannedEvictions(
        scan: DiskScan, destination: String, reserving: Int
    ) -> [DiskEntry]? {
        let existing = scan.entries.first { $0.name == destination }
        var entries = scan.entries
            .filter { $0.name != destination }
            .sorted { $0.accessedAt < $1.accessedAt }
        var occupiedBytes = scan.occupiedBytes - (existing?.byteCount ?? 0)
        var entryCount = entries.count + 1
        var evictions: [DiskEntry] = []
        while needsDiskEviction(
            occupiedBytes: occupiedBytes, reserving: reserving, entryCount: entryCount
        ) {
            guard let oldest = entries.first else { return nil }
            entries.removeFirst()
            occupiedBytes -= oldest.byteCount
            entryCount -= 1
            evictions.append(oldest)
        }
        return evictions
    }

    private func needsDiskEviction(
        occupiedBytes: Int, reserving: Int, entryCount: Int
    ) -> Bool {
        occupiedBytes + reserving > Self.maxDiskBytes || entryCount > Self.maxDiskEntries
    }

    func discardDiskEntry(_ identity: LocaleCatalogIdentity) {
        guard let rootFD = LocaleCatalogPOSIX.openDirectory(path: root.path()) else { return }
        defer { LocaleCatalogPOSIX.closeDescriptor(rootFD) }
        _ = LocaleCatalogPOSIX.remove(parent: rootFD, name: Self.directoryName(for: identity))
    }

    private func readEntryRecord(
        rootFD: Int32, name: String, byteCount: Int? = nil
    ) -> DiskEntry? {
        guard let directoryFD = LocaleCatalogPOSIX.openDirectory(parent: rootFD, name: name) else {
            return nil
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        guard let bytes = LocaleCatalogPOSIX.readRegular(
            parent: directoryFD, name: Self.entryRecordName, maxBytes: 4096
        ), let value = try? LosslessJSONParser.parse(bytes, maxByteCount: 4096),
        case let .object(object) = value,
        Set(object.keys) == [
            "endpoint", "catalogRevision", "locale", "manifestSha256", "accessedAt",
        ],
        case let .string(endpoint)? = object["endpoint"],
        case let .string(catalogRevision)? = object["catalogRevision"],
        case let .string(locale)? = object["locale"],
        case let .string(manifestSha256)? = object["manifestSha256"],
        let accessedAt = LocaleCatalogManifest.nonNegativeInteger(object["accessedAt"])
        else {
            return nil
        }
        return DiskEntry(
            endpoint: endpoint,
            catalogRevision: catalogRevision,
            locale: locale,
            manifestSha256: manifestSha256,
            accessedAt: Date(timeIntervalSince1970: TimeInterval(accessedAt)),
            name: name,
            byteCount: byteCount ?? 0
        )
    }

    private func writeEntryRecord(
        identity: LocaleCatalogIdentity,
        directoryFD: Int32,
        name: String = FileLocaleCatalogStore.entryRecordName
    ) -> Bool {
        let timestamp = max(Int(clock.now.timeIntervalSince1970), 0)
        let record = """
        {"endpoint":\(jsonString(identity.endpoint)),\
        "catalogRevision":\(jsonString(identity.catalogRevision)),\
        "locale":\(jsonString(identity.locale)),\
        "manifestSha256":\(jsonString(identity.manifestSha256)),\
        "accessedAt":\(timestamp)}
        """
        return LocaleCatalogPOSIX.writeRegular(
            Data(record.utf8), parent: directoryFD, name: name
        )
    }

    private func writeEntryRecord(
        identity: LocaleCatalogIdentity, rootFD: Int32, entryName: String
    ) -> Bool {
        guard let directoryFD = LocaleCatalogPOSIX.openDirectory(
            parent: rootFD, name: entryName
        ) else {
            return false
        }
        defer { LocaleCatalogPOSIX.closeDescriptor(directoryFD) }
        defer {
            _ = LocaleCatalogPOSIX.removeIfPresent(
                parent: directoryFD, name: Self.entryRecordStagingName
            )
        }
        guard writeEntryRecord(
            identity: identity,
            directoryFD: directoryFD,
            name: Self.entryRecordStagingName
        ), LocaleCatalogPOSIX.replace(
            parent: directoryFD,
            from: Self.entryRecordStagingName,
            to: Self.entryRecordName
        ) else {
            return false
        }
        return LocaleCatalogPOSIX.syncDirectory(directoryFD)
    }

    private func isEntryName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private func jsonString(_ text: String) -> String {
        var escaped = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case let value where value.value < 0x20:
                escaped += String(format: "\\u%04x", value.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }
}

enum LocaleCatalogPOSIX {
    typealias MoveGate = @Sendable (_ source: String, _ destination: String) -> Bool
    typealias WriteGate = @Sendable (_ name: String) -> Bool

    @TaskLocal static var tracker: LocaleCatalogDescriptorTracker?
    @TaskLocal static var moveGate: MoveGate?
    @TaskLocal static var writeGate: WriteGate?

    static func openDirectory(path: String) -> Int32? {
        guard let normalizedPath = normalizedDirectoryPath(path) else {
            return nil
        }
        var expected = stat()
        guard lstat(normalizedPath, &expected) == 0, isDirectory(expected) else {
            return nil
        }
        let descriptor = open(normalizedPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        opened(descriptor)
        var actual = stat()
        let matchesExpected = fstat(descriptor, &actual) == 0
            && isDirectory(actual)
            && sameNode(expected, actual)
        guard matchesExpected else {
            closeDescriptor(descriptor)
            return nil
        }
        return descriptor
    }

    static func openOrCreateDirectory(path: String) -> Int32? {
        guard let normalizedPath = normalizedDirectoryPath(path) else {
            return nil
        }
        if mkdir(normalizedPath, 0o700) != 0, errno != EEXIST {
            return nil
        }
        return openDirectory(path: normalizedPath)
    }

    static func openDirectory(parent: Int32, name: String) -> Int32? {
        var expected = stat()
        guard fstatat(parent, name, &expected, AT_SYMLINK_NOFOLLOW) == 0,
              isDirectory(expected)
        else {
            return nil
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        opened(descriptor)
        var actual = stat()
        let matchesExpected = fstat(descriptor, &actual) == 0
            && isDirectory(actual)
            && sameNode(expected, actual)
        guard matchesExpected else {
            closeDescriptor(descriptor)
            return nil
        }
        return descriptor
    }

    static func makeDirectory(parent: Int32, name: String) -> Bool {
        mkdirat(parent, name, 0o700) == 0
    }

    static func moveExclusive(parent: Int32, from source: String, to destination: String) -> Bool {
        guard moveGate?(source, destination) ?? true else { return false }
        return renameatx_np(
            parent, source, parent, destination, UInt32(RENAME_EXCL)
        ) == 0
    }

    static func swap(parent: Int32, first: String, second: String) -> Bool {
        guard moveGate?(first, second) ?? true else { return false }
        return renameatx_np(
            parent, first, parent, second, UInt32(RENAME_SWAP)
        ) == 0
    }

    static func syncDirectory(_ descriptor: Int32) -> Bool {
        fsync(descriptor) == 0
    }

    static func names(in directoryFD: Int32, limit: Int) -> [String]? {
        let copiedFD = dup(directoryFD)
        guard copiedFD >= 0 else {
            return nil
        }
        opened(copiedFD)
        guard let directory = fdopendir(copiedFD) else {
            closeDescriptor(copiedFD)
            return nil
        }
        defer { closeDirectory(directory, descriptor: copiedFD) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                return errno == 0 ? names : nil
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            guard names.count < limit else {
                return nil
            }
            names.append(name)
        }
        return names
    }

    static func readRegular(parent: Int32, name: String, maxBytes: Int) -> Data? {
        var expected = stat()
        guard fstatat(parent, name, &expected, AT_SYMLINK_NOFOLLOW) == 0,
              isRegular(expected)
        else {
            return nil
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        opened(descriptor)
        defer { closeDescriptor(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isRegular(metadata),
              sameNode(expected, metadata),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maxBytes)
        else {
            return nil
        }
        let count = Int(metadata.st_size)
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer in
            guard let start = buffer.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let amount = read(descriptor, start.advanced(by: offset), count - offset)
                guard amount > 0 else { return false }
                offset += Int(amount)
            }
            return true
        }
        return complete ? data : nil
    }

    static func writeRegular(_ data: Data, parent: Int32, name: String) -> Bool {
        guard writeGate?(name) ?? true else { return false }
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        opened(descriptor)
        defer { closeDescriptor(descriptor) }
        let complete = data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let amount = write(descriptor, start.advanced(by: offset), data.count - offset)
                guard amount > 0 else { return false }
                offset += Int(amount)
            }
            return true
        }
        return complete && fsync(descriptor) == 0
    }

    static func directorySize(parent: Int32, name: String, fileLimit: Int) -> Int? {
        guard let directoryFD = openDirectory(parent: parent, name: name) else {
            return nil
        }
        defer { closeDescriptor(directoryFD) }
        guard let names = names(in: directoryFD, limit: fileLimit) else {
            return nil
        }
        var total = 0
        for child in names {
            var metadata = stat()
            guard fstatat(directoryFD, child, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  isRegular(metadata),
                  metadata.st_size >= 0,
                  metadata.st_size <= off_t(FileLocaleCatalogStore.maxDiskBytes),
                  total <= FileLocaleCatalogStore.maxDiskBytes - Int(metadata.st_size)
            else {
                return nil
            }
            total += Int(metadata.st_size)
        }
        return total
    }

    static func removeIfPresent(parent: Int32, name: String) -> Bool {
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT
        }
        return remove(parent: parent, name: name)
    }

    static func remove(parent: Int32, name: String) -> Bool {
        var budget = FileLocaleCatalogStore.maxEntryFiles + 1
        return remove(parent: parent, name: name, budget: &budget)
    }

    private static func remove(parent: Int32, name: String, budget: inout Int) -> Bool {
        guard budget > 0 else { return false }
        budget -= 1
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT
        }
        guard isDirectory(metadata) else {
            return unlinkat(parent, name, 0) == 0
        }
        guard let directoryFD = openDirectory(parent: parent, name: name) else {
            return false
        }
        defer { closeDescriptor(directoryFD) }
        guard let children = names(in: directoryFD, limit: budget) else {
            return false
        }
        for child in children {
            guard remove(parent: directoryFD, name: child, budget: &budget) else {
                return false
            }
        }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
    }

    private static func isRegular(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private static func isDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func normalizedDirectoryPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard path == "/" || !path.hasSuffix("/") else {
            return String(path.dropLast())
        }
        return path
    }

    private static func opened(_ descriptor: Int32) {
        tracker?.opened(descriptor)
    }

    static func closeDescriptor(_ descriptor: Int32) {
        let result = Darwin.close(descriptor)
        let closeErrno = errno
        tracker?.closed(descriptor, succeeded: result == 0, errorCode: closeErrno)
    }

    private static func closeDirectory(
        _ directory: UnsafeMutablePointer<DIR>,
        descriptor: Int32
    ) {
        let result = closedir(directory)
        let closeErrno = errno
        tracker?.closed(descriptor, succeeded: result == 0, errorCode: closeErrno)
    }
}

extension LocaleCatalogPOSIX {
    static func replace(parent: Int32, from source: String, to destination: String) -> Bool {
        guard moveGate?(source, destination) ?? true else { return false }
        return renameat(parent, source, parent, destination) == 0
    }
}

final class LocaleCatalogDescriptorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: Set<Int32> = []
    private var duplicateAcquisitions = 0
    private var failedCloses = 0
    private var unknownCloses = 0

    func opened(_ descriptor: Int32) {
        lock.lock()
        if !descriptors.insert(descriptor).inserted {
            duplicateAcquisitions += 1
        }
        lock.unlock()
    }

    func closed(_ descriptor: Int32, succeeded: Bool, errorCode _: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard succeeded else {
            failedCloses += 1
            return
        }
        guard descriptors.remove(descriptor) != nil else {
            unknownCloses += 1
            return
        }
    }

    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.count
    }

    var violationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return duplicateAcquisitions + failedCloses + unknownCloses
    }

    var isClean: Bool {
        outstandingCount == 0 && violationCount == 0
    }
}

extension LocaleCatalogPOSIX {
    /// The size of the regular file `name`, or `nil` when it is absent or not a regular file
    /// (which ``directorySize(parent:name:fileLimit:)`` would not have counted either).
    static func regularFileSize(parent: Int32, name: String) -> Int? {
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              isRegular(metadata),
              metadata.st_size >= 0
        else {
            return nil
        }
        return Int(metadata.st_size)
    }
}

// swiftlint:enable file_length
