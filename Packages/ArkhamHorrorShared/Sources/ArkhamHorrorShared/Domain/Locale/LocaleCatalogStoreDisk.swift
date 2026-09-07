import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

extension FileLocaleCatalogStore {
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
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        for chainLocale in manifest.localeChain(from: identity.locale) {
            guard let record = manifest.record(for: chainLocale) else { return nil }
            for descriptor in record.chunks {
                guard chunks.count < LocaleCatalogLimits.maxSnapshotChunks,
                      let chunk = readChunk(
                          directoryFD: directoryFD,
                          descriptor: descriptor,
                          locale: chainLocale,
                          fallback: record.fallback
                      )
                else {
                    return nil
                }
                chunks[LocaleCatalogChunkKey(locale: chainLocale, pack: descriptor.pack)] = chunk
            }
        }
        let snapshot = LocaleCatalogSnapshot(
            identity: identity, manifest: manifest, chunks: chunks
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
            guard let size = LocaleCatalogPOSIX.directorySize(
                parent: rootFD, name: name, fileLimit: Self.maxEntryFiles
            ) else {
                guard LocaleCatalogPOSIX.remove(parent: rootFD, name: name) else {
                    return nil
                }
                continue
            }
            guard let entry = readEntryRecord(rootFD: rootFD, name: name, byteCount: size)
            else {
                guard LocaleCatalogPOSIX.remove(parent: rootFD, name: name) else {
                    return nil
                }
                continue
            }
            let nextBytes = scan.occupiedBytes.addingReportingOverflow(size)
            guard !nextBytes.overflow else { return nil }
            scan.occupiedBytes = nextBytes.partialValue
            scan.entries.append(entry)
        }
        return pruneScan(scan, rootFD: rootFD)
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
        for locale in snapshot.localeChain {
            guard let record = snapshot.manifest.record(for: locale) else { return }
            for descriptor in record.chunks {
                guard let bytes = chunkBytes[descriptor.sha256],
                      LocaleCatalogPOSIX.writeRegular(
                          bytes, parent: stagingFD, name: "\(descriptor.sha256).json"
                      )
                else {
                    return
                }
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

    private func payloadByteCount(
        snapshot: LocaleCatalogSnapshot,
        manifestBytes: Data,
        chunkBytes: [String: Data]
    ) -> Int? {
        var total = manifestBytes.count
        var seenDigests: Set<String> = []
        for locale in snapshot.localeChain {
            guard let record = snapshot.manifest.record(for: locale) else { return nil }
            for descriptor in record.chunks where seenDigests.insert(descriptor.sha256).inserted {
                guard let bytes = chunkBytes[descriptor.sha256],
                      bytes.count == descriptor.bytes
                else {
                    return nil
                }
                let next = total.addingReportingOverflow(bytes.count)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
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
            parent: directoryFD, name: "entry.json", maxBytes: 4096
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

    private func writeEntryRecord(identity: LocaleCatalogIdentity, directoryFD: Int32) -> Bool {
        let timestamp = max(Int(clock.now.timeIntervalSince1970), 0)
        let record = """
        {"endpoint":\(jsonString(identity.endpoint)),\
        "catalogRevision":\(jsonString(identity.catalogRevision)),\
        "locale":\(jsonString(identity.locale)),\
        "manifestSha256":\(jsonString(identity.manifestSha256)),\
        "accessedAt":\(timestamp)}
        """
        return LocaleCatalogPOSIX.writeRegular(
            Data(record.utf8), parent: directoryFD, name: "entry.json"
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
        _ = LocaleCatalogPOSIX.removeIfPresent(parent: directoryFD, name: "entry.json")
        return writeEntryRecord(identity: identity, directoryFD: directoryFD)
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

    @TaskLocal static var tracker: LocaleCatalogDescriptorTracker?
    @TaskLocal static var moveGate: MoveGate?

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

// swiftlint:enable file_length
