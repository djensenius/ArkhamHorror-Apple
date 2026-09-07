import Foundation

// swiftlint:disable file_length

/// The v1 locale-catalog manifest (`frontend/schemas/locale-catalog/v1/manifest.schema.json`),
/// after complete validation.
///
/// This type only ever exists for a manifest whose bytes already hashed to the digest the
/// capabilities advertisement pinned, and whose every field satisfied the closed schema. It
/// deliberately keeps only what a client needs to fetch and resolve: the provenance and
/// backend-gap blocks are validated (they are `required`, so their absence or malformation
/// makes the document invalid) but not retained, because nothing this client renders may
/// depend on them.
struct LocaleCatalogManifest: Sendable, Equatable {
    let catalogRevision: String
    let defaultLocale: String
    /// The published locales in the order the manifest lists them.
    let locales: [LocaleCatalogLocaleRecord]
    /// How the production web client maps BCP-47 tags to catalog locales, so this client
    /// cannot drift from it.
    let languageResolution: [String: String]
    let totals: LocaleCatalogTotals

    /// The record for `locale`, or `nil` when the catalog does not publish it. Each locale
    /// appears exactly once (enforced during validation), so this is unambiguous.
    func record(for locale: String) -> LocaleCatalogLocaleRecord? {
        locales.first { $0.locale == locale }
    }

    /// The resolution chain for `locale`: itself, then each fallback in turn, ending at the
    /// default locale. Validation already proved the graph acyclic and default-terminating,
    /// so the visited set here is a belt-and-braces bound rather than the cycle check.
    func localeChain(from locale: String) -> [String] {
        var chain: [String] = []
        var cursor: String? = locale
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current).inserted {
            chain.append(current)
            cursor = record(for: current)?.fallback
        }
        return chain
    }

    var supportedLocales: [String] {
        locales.map(\.locale)
    }
}

/// One published locale: its fallback, its chunks, and the totals it attests to.
struct LocaleCatalogLocaleRecord: Sendable, Equatable {
    let locale: String
    /// The locale a missing key or unresolved link is resolved against; `nil` only for the
    /// default locale.
    let fallback: String?
    let chunks: [LocaleCatalogChunkDescriptor]
    let keys: Int
    let bytes: Int
}

/// One content-addressed chunk the manifest promises, pinned by size and digest.
struct LocaleCatalogChunkDescriptor: Sendable, Equatable {
    let pack: String
    /// `/locale-catalog/c/<sha256>.json`; the file name is always ``sha256``.
    let path: String
    let bytes: Int
    let sha256: String
    let keys: Int
    let unsupportedKeys: Int
}

/// The manifest's self-attested totals, recomputed from the locale records during
/// validation so a manifest cannot claim small totals and then list the same 8 MiB chunk
/// four thousand times.
struct LocaleCatalogTotals: Sendable, Equatable {
    let locales: Int
    let chunks: Int
    let bytes: Int
    let keys: Int
    let unsupportedKeys: Int
}

// MARK: - Decoding

extension LocaleCatalogManifest {
    /// Validates and decodes a manifest from already-parsed JSON.
    ///
    /// The caller is responsible for having parsed those bytes through ``ContractJSON``'s
    /// lossless parser (which rejects duplicate keys, invalid UTF-8, and trailing data) and
    /// for having verified the SHA-256 digest *before* calling this. This function assumes
    /// nothing about the bytes' provenance beyond that and re-derives everything it can:
    ///
    /// - every fixed route (`basePath`, `manifestPath`, `chunkPathPrefix`, `digestAlgorithm`,
    ///   `schemaVersion`) is compared against the `const` the schema pins, never read as
    ///   configuration;
    /// - `revisionManifestPath` must be exactly the path `catalogRevision` derives;
    /// - `catalogRevision`, `defaultLocale` and the whole locale set must equal what the
    ///   capabilities advertisement promised, so a manifest can never redirect a client onto
    ///   a different catalog than the one whose digest it verified;
    /// - each locale appears exactly once, the default locale is the only one without a
    ///   fallback, and every fallback and language-resolution target is a published locale
    ///   whose fallback chain terminates at the default without a cycle;
    /// - `(locale, pack)` pairs and chunk paths are unique, a digest names exactly one path,
    ///   and every path is `chunkPathPrefix + sha256 + ".json"`;
    /// - every declared count and byte total is recomputed and must match exactly;
    /// - every ceiling in ``LocaleCatalogLimits`` is enforced.
    static func validate(
        _ value: JSONValue, against advertisement: LocaleCatalogAdvertisement
    ) -> Result<LocaleCatalogManifest, LocaleCatalogFailure> {
        guard case let .object(object) = value else { return .failure(.malformedManifest) }
        let required: Set = [
            "schemaVersion", "catalogRevision", "basePath", "manifestPath",
            "revisionManifestPath", "chunkPathPrefix", "digestAlgorithm", "defaultLocale",
            "languageResolution", "locales", "totals", "backend", "provenance",
        ]
        guard Set(object.keys) == required else { return .failure(.malformedManifest) }
        guard object["schemaVersion"] == .string(LocaleCatalogLimits.schemaVersion),
              object["basePath"] == .string(LocaleCatalogLimits.basePath),
              object["manifestPath"] == .string(LocaleCatalogLimits.manifestPath),
              object["chunkPathPrefix"] == .string(LocaleCatalogLimits.chunkPathPrefix),
              object["digestAlgorithm"] == .string(LocaleCatalogLimits.digestAlgorithm)
        else { return .failure(.malformedManifest) }
        guard case let .string(catalogRevision)? = object["catalogRevision"],
              LocaleCatalogGrammar.isCatalogRevision(catalogRevision),
              object["revisionManifestPath"]
              == .string(LocaleCatalogGrammar.revisionManifestPath(for: catalogRevision)),
              case let .string(defaultLocale)? = object["defaultLocale"],
              LocaleCatalogGrammar.isCatalogLocaleTag(defaultLocale)
        else { return .failure(.malformedManifest) }
        guard catalogRevision == advertisement.catalogRevision,
              defaultLocale == advertisement.defaultLocale
        else { return .failure(.advertisementMismatch) }
        guard validateBackendBlock(object["backend"]),
              validateProvenanceBlock(object["provenance"])
        else { return .failure(.malformedManifest) }

        guard let locales = decodeLocales(object["locales"]) else {
            return .failure(.malformedManifest)
        }
        guard locales.map(\.locale) == advertisement.supportedLocales else {
            return .failure(.advertisementMismatch)
        }
        guard let languageResolution = decodeLanguageResolution(
            object["languageResolution"], locales: Set(locales.map(\.locale))
        ) else { return .failure(.malformedManifest) }
        guard validateFallbackGraph(locales, defaultLocale: defaultLocale),
              validateChunkUniqueness(locales),
              let totals = decodeTotals(object["totals"]),
              let recomputedTotals = recomputedTotals(locales),
              totals == recomputedTotals
        else { return .failure(.malformedManifest) }

        return .success(LocaleCatalogManifest(
            catalogRevision: catalogRevision,
            defaultLocale: defaultLocale,
            locales: locales,
            languageResolution: languageResolution,
            totals: totals
        ))
    }

    // MARK: Locales

    private static func decodeLocales(_ value: JSONValue?) -> [LocaleCatalogLocaleRecord]? {
        guard case let .array(elements)? = value,
              (1 ... LocaleCatalogLimits.maxLocales).contains(elements.count)
        else { return nil }
        var records: [LocaleCatalogLocaleRecord] = []
        records.reserveCapacity(elements.count)
        for element in elements {
            guard let record = decodeLocaleRecord(element) else { return nil }
            records.append(record)
        }
        // Each locale must appear exactly once: a locale split across two records would
        // leave a client reading a slice that only looks complete.
        guard Set(records.map(\.locale)).count == records.count else { return nil }
        return records
    }

    private static func decodeLocaleRecord(_ value: JSONValue) -> LocaleCatalogLocaleRecord? {
        guard case let .object(object) = value,
              Set(object.keys) == ["locale", "fallback", "chunks", "keys", "bytes"],
              case let .string(locale)? = object["locale"],
              LocaleCatalogGrammar.isCatalogLocaleTag(locale),
              let keys = nonNegativeInteger(object["keys"]),
              let bytes = nonNegativeInteger(object["bytes"]),
              let chunks = decodeChunks(object["chunks"])
        else { return nil }
        let fallback: String?
        switch object["fallback"] {
        case let .string(tag)?:
            guard LocaleCatalogGrammar.isCatalogLocaleTag(tag) else { return nil }
            fallback = tag
        case .null?:
            fallback = nil
        default:
            return nil
        }
        // A locale's own attested totals must equal the sum of its chunks', so a per-locale
        // figure can never disagree with what a client would have to download.
        guard let recomputedKeys = checkedSum(chunks.map(\.keys)),
              let recomputedBytes = checkedSum(chunks.map(\.bytes)),
              recomputedKeys == keys,
              recomputedBytes == bytes
        else { return nil }
        return LocaleCatalogLocaleRecord(
            locale: locale, fallback: fallback, chunks: chunks, keys: keys, bytes: bytes
        )
    }

    private static func decodeChunks(_ value: JSONValue?) -> [LocaleCatalogChunkDescriptor]? {
        guard case let .array(elements)? = value,
              (1 ... LocaleCatalogLimits.maxChunksPerLocale).contains(elements.count)
        else { return nil }
        var chunks: [LocaleCatalogChunkDescriptor] = []
        chunks.reserveCapacity(elements.count)
        for element in elements {
            guard let chunk = decodeChunkDescriptor(element) else { return nil }
            chunks.append(chunk)
        }
        // A pack may appear at most once per locale: two descriptors for one pack would let
        // a client silently read only half of it.
        guard Set(chunks.map(\.pack)).count == chunks.count else { return nil }
        return chunks
    }

    private static func decodeChunkDescriptor(
        _ value: JSONValue
    ) -> LocaleCatalogChunkDescriptor? {
        guard case let .object(object) = value,
              Set(object.keys) == ["pack", "path", "bytes", "sha256", "keys", "unsupportedKeys"],
              case let .string(pack)? = object["pack"],
              LocaleCatalogGrammar.isPackIdentifier(pack),
              case let .string(path)? = object["path"],
              case let .string(sha256)? = object["sha256"],
              LocaleCatalogGrammar.isSHA256Hex(sha256),
              path == LocaleCatalogGrammar.chunkPath(forDigest: sha256),
              let bytes = nonNegativeInteger(object["bytes"]),
              bytes <= LocaleCatalogLimits.maxChunkBytes,
              let keys = nonNegativeInteger(object["keys"]),
              let unsupportedKeys = nonNegativeInteger(object["unsupportedKeys"]),
              unsupportedKeys <= keys
        else { return nil }
        return LocaleCatalogChunkDescriptor(
            pack: pack, path: path, bytes: bytes,
            sha256: sha256, keys: keys, unsupportedKeys: unsupportedKeys
        )
    }

    // MARK: Graphs and totals

    /// Every fallback target is a published locale, the default locale is the only one
    /// without a fallback, and every chain terminates at the default. Self-references,
    /// cycles, and chains that never reach the default are all refused.
    private static func validateFallbackGraph(
        _ locales: [LocaleCatalogLocaleRecord], defaultLocale: String
    ) -> Bool {
        let byLocale = Dictionary(uniqueKeysWithValues: locales.map { ($0.locale, $0) })
        guard let defaultRecord = byLocale[defaultLocale], defaultRecord.fallback == nil else {
            return false
        }
        for record in locales where record.locale != defaultLocale {
            guard var cursor = record.fallback else { return false }
            var visited: Set<String> = [record.locale]
            var steps = 0
            while cursor != defaultLocale {
                guard steps < locales.count, visited.insert(cursor).inserted,
                      let next = byLocale[cursor]?.fallback
                else { return false }
                cursor = next
                steps += 1
            }
        }
        return true
    }

    /// A content path may be claimed by exactly one digest across the whole catalog, and the
    /// catalog as a whole must stay inside the file-count and byte ceilings.
    private static func validateChunkUniqueness(_ locales: [LocaleCatalogLocaleRecord]) -> Bool {
        var digestForPath: [String: String] = [:]
        var totalFiles = 1 // the manifest itself
        var totalBytes = 0
        for record in locales {
            for chunk in record.chunks {
                if digestForPath[chunk.path] != nil {
                    return false
                }
                digestForPath[chunk.path] = chunk.sha256
                let nextFileCount = totalFiles.addingReportingOverflow(1)
                let nextByteCount = totalBytes.addingReportingOverflow(chunk.bytes)
                guard !nextFileCount.overflow, !nextByteCount.overflow else {
                    return false
                }
                totalFiles = nextFileCount.partialValue
                totalBytes = nextByteCount.partialValue
            }
        }
        return totalFiles <= LocaleCatalogLimits.maxCatalogFiles
            && totalBytes <= LocaleCatalogLimits.maxCatalogBytes
    }

    /// Totals are recomputed from the **unique** chunk set, exactly as the backend's own
    /// `verify-dist.mjs` does, so a shared chunk is counted once no matter how many locales
    /// reference it.
    private static func recomputedTotals(
        _ locales: [LocaleCatalogLocaleRecord]
    ) -> LocaleCatalogTotals? {
        var seenPaths: Set<String> = []
        var chunks = 0
        var bytes = 0
        var keys = 0
        var unsupportedKeys = 0
        for record in locales {
            for chunk in record.chunks where seenPaths.insert(chunk.path).inserted {
                let nextChunkCount = chunks.addingReportingOverflow(1)
                let nextByteCount = bytes.addingReportingOverflow(chunk.bytes)
                let nextKeyCount = keys.addingReportingOverflow(chunk.keys)
                let nextUnsupportedCount = unsupportedKeys.addingReportingOverflow(
                    chunk.unsupportedKeys
                )
                guard !nextChunkCount.overflow, !nextByteCount.overflow,
                      !nextKeyCount.overflow, !nextUnsupportedCount.overflow
                else {
                    return nil
                }
                chunks = nextChunkCount.partialValue
                bytes = nextByteCount.partialValue
                keys = nextKeyCount.partialValue
                unsupportedKeys = nextUnsupportedCount.partialValue
            }
        }
        return LocaleCatalogTotals(
            locales: locales.count, chunks: chunks,
            bytes: bytes, keys: keys, unsupportedKeys: unsupportedKeys
        )
    }

    private static func decodeTotals(_ value: JSONValue?) -> LocaleCatalogTotals? {
        guard case let .object(object) = value,
              Set(object.keys) == ["locales", "chunks", "bytes", "keys", "unsupportedKeys"],
              let locales = nonNegativeInteger(object["locales"]),
              let chunks = nonNegativeInteger(object["chunks"]),
              let bytes = nonNegativeInteger(object["bytes"]),
              let keys = nonNegativeInteger(object["keys"]),
              let unsupportedKeys = nonNegativeInteger(object["unsupportedKeys"])
        else { return nil }
        return LocaleCatalogTotals(
            locales: locales, chunks: chunks,
            bytes: bytes, keys: keys, unsupportedKeys: unsupportedKeys
        )
    }

    /// The `tag -> locale` table, refused outright if a tag resolves two ways or names a
    /// locale the catalog does not publish.
    private static func decodeLanguageResolution(
        _ value: JSONValue?, locales: Set<String>
    ) -> [String: String]? {
        guard case let .array(elements)? = value, !elements.isEmpty,
              elements.count <= LocaleCatalogLimits.maxLanguageResolutionEntries
        else { return nil }
        var table: [String: String] = [:]
        table.reserveCapacity(elements.count)
        for element in elements {
            guard case let .object(object) = element,
                  Set(object.keys) == ["tag", "locale"],
                  case let .string(tag)? = object["tag"],
                  LocaleCatalogGrammar.isLanguageResolutionTag(tag),
                  let normalizedTag = LocaleCatalogGrammar.asciiLowercased(tag),
                  case let .string(locale)? = object["locale"],
                  locales.contains(locale),
                  table.updateValue(locale, forKey: normalizedTag) == nil
            else { return nil }
        }
        return table
    }

    // MARK: Required blocks this client validates but does not retain

    /// `backend` is `required` and closed, so a malformed or absent block invalidates the
    /// whole manifest. Its contents describe the deployment's own published gaps; nothing
    /// this client renders depends on them, so they are checked and discarded rather than
    /// retained as state that could drift.
    private static func validateBackendBlock(_ value: JSONValue?) -> Bool {
        guard case let .object(object) = value,
              Set(object.keys) == [
                  "artifactPath", "artifactSha256", "sourceSha256", "emittedKeys",
                  "requiredKeys", "untranslatedKeys", "variableGaps", "dynamicSites",
                  "unknownVariableTypes",
              ],
              case let .string(artifactPath)? = object["artifactPath"],
              !artifactPath.isEmpty, artifactPath.hasSuffix(".json"),
              case let .string(artifactSha256)? = object["artifactSha256"],
              LocaleCatalogGrammar.isSHA256Hex(artifactSha256),
              case let .string(sourceSha256)? = object["sourceSha256"],
              LocaleCatalogGrammar.isSHA256Hex(sourceSha256),
              nonNegativeInteger(object["emittedKeys"]) != nil,
              nonNegativeInteger(object["requiredKeys"]) != nil,
              nonNegativeInteger(object["dynamicSites"]) != nil,
              case let .array(untranslated)? = object["untranslatedKeys"],
              untranslated.allSatisfy(isMessageKeyValue),
              Set(untranslated.compactMap(stringValue)).count == untranslated.count,
              case let .array(variableGaps)? = object["variableGaps"],
              variableGaps.allSatisfy(isVariableGap),
              case let .array(unknownVariableTypes)? = object["unknownVariableTypes"],
              unknownVariableTypes.allSatisfy(isUnknownVariableType)
        else { return false }
        return true
    }

    /// `provenance` binds the revision to the exact bytes it was generated from. Validated
    /// for shape and for the one field this client can independently check — the generator's
    /// pinned name — then discarded.
    private static func validateProvenanceBlock(_ value: JSONValue?) -> Bool {
        guard case let .object(object) = value,
              Set(object.keys) == [
                  "sha256", "outputSha256", "generator", "contractRevision", "fixtureKeys",
                  "localeSourceFiles", "localeSourcesSha256", "schemasSha256", "generatorSha256",
              ],
              case let .string(sha256)? = object["sha256"],
              LocaleCatalogGrammar.isSHA256Hex(sha256),
              case let .string(outputSha256)? = object["outputSha256"],
              LocaleCatalogGrammar.isSHA256Hex(outputSha256),
              case let .string(localeSourcesSha256)? = object["localeSourcesSha256"],
              LocaleCatalogGrammar.isSHA256Hex(localeSourcesSha256),
              case let .string(schemasSha256)? = object["schemasSha256"],
              LocaleCatalogGrammar.isSHA256Hex(schemasSha256),
              case let .string(generatorSha256)? = object["generatorSha256"],
              LocaleCatalogGrammar.isSHA256Hex(generatorSha256),
              nonNegativeInteger(object["localeSourceFiles"]) != nil,
              case let .object(generator)? = object["generator"],
              Set(generator.keys) == ["name", "version"],
              generator["name"] == .string(LocaleCatalogLimits.generatorName),
              case let .string(generatorVersion)? = generator["version"],
              isSemanticVersion(generatorVersion),
              case let .string(contractRevision)? = object["contractRevision"],
              isRevision(contractRevision),
              case let .array(fixtureKeys)? = object["fixtureKeys"],
              !fixtureKeys.isEmpty,
              fixtureKeys.allSatisfy(isMessageKeyValue),
              Set(fixtureKeys.compactMap(stringValue)).count == fixtureKeys.count
        else { return false }
        return true
    }

    private static func isMessageKeyValue(_ value: JSONValue) -> Bool {
        guard case let .string(key) = value else { return false }
        return LocaleCatalogGrammar.isMessageKey(key)
    }

    private static func stringValue(_ value: JSONValue) -> String? {
        guard case let .string(text) = value else { return nil }
        return text
    }

    private static func isVariableGap(_ value: JSONValue) -> Bool {
        guard case let .object(object) = value,
              Set(object.keys) == ["key", "missing", "resolved"],
              isMessageKeyValue(object["key"] ?? .null),
              case let .array(missing)? = object["missing"],
              missing.allSatisfy(isVariableNameValue),
              case .bool? = object["resolved"]
        else {
            return false
        }
        return true
    }

    private static func isUnknownVariableType(_ value: JSONValue) -> Bool {
        guard case let .object(object) = value,
              Set(object.keys) == ["key", "variable", "role", "type"],
              isMessageKeyValue(object["key"] ?? .null),
              isVariableNameValue(object["variable"] ?? .null),
              object["role"] == .string("text"),
              case let .string(type)? = object["type"],
              type.count <= 32
        else {
            return false
        }
        return true
    }

    private static func isVariableNameValue(_ value: JSONValue) -> Bool {
        guard case let .string(name) = value else { return false }
        return LocaleCatalogGrammar.isVariableName(name)
    }

    private static func isSemanticVersion(_ text: String) -> Bool {
        let parts = LocaleCatalogGrammar.splitASCII(text, separator: 0x2E)
        return parts.count == 3
            && parts.allSatisfy(isDigits)
    }

    private static func isRevision(_ text: String) -> Bool {
        let parts = LocaleCatalogGrammar.splitASCII(text, separator: 0x2E)
        return !parts.isEmpty
            && parts.allSatisfy(isDigits)
    }

    private static func isDigits(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { (0x30 ... 0x39).contains($0) }
    }

    /// A canonical JSON integer `>= 0`: no sign, no exponent, no leading zero, no fractional
    /// part. Read from the number's own retained token (see ``JSONNumber``), so `1e2` and
    /// `1.0` are refused rather than silently coerced into `100` and `1`.
    static func nonNegativeInteger(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let raw = number.rawToken
        else { return nil }
        return LocaleCatalogGrammar.canonicalInteger(Array(raw.utf8), upperBound: Int.max)
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
