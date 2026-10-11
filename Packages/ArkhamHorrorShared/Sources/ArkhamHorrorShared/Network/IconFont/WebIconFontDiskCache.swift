import CryptoKit
import Foundation

struct WebIconFontCacheKey: Sendable, Hashable, Codable {
    let urlString: String
    let validator: String
    let lastModified: String?

    init(url: URL, etag: String?, lastModified: String?, data: Data) {
        urlString = url.absoluteString
        let normalizedETag = etag.flatMap(Self.nonEmpty)
        let normalizedLastModified = lastModified.flatMap(Self.nonEmpty)
        self.lastModified = normalizedLastModified
        if let normalizedETag {
            validator = "etag:\(normalizedETag)"
        } else if let normalizedLastModified {
            validator = "last-modified:\(normalizedLastModified)"
        } else {
            validator = "sha256:\(Self.sha256Hex(data))"
        }
    }

    var etagHeader: String? {
        value(forPrefix: "etag:")
    }

    var lastModifiedHeader: String? {
        lastModified ?? value(forPrefix: "last-modified:")
    }

    private func value(forPrefix prefix: String) -> String? {
        guard validator.hasPrefix(prefix) else { return nil }
        return String(validator.dropFirst(prefix.count))
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct WebIconFontDiskCache: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultCache() -> WebIconFontDiskCache? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return WebIconFontDiskCache(
            root: root.appendingPathComponent("WebIconFonts", isDirectory: true)
        )
    }

    func store(data: Data, key: WebIconFontCacheKey) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = metadataURL(for: key.urlString)
        let oldPayloadURL = existingPayloadURL(metadataURL: metadataURL)
        let newPayloadURL = payloadURL(for: key)
        try data.write(to: newPayloadURL, options: [.atomic])
        let metadata = Metadata(key: key)
        let encoded = try JSONEncoder().encode(metadata)
        try encoded.write(to: metadataURL, options: [.atomic])
        if let oldPayloadURL, oldPayloadURL != newPayloadURL {
            try? fileManager.removeItem(at: oldPayloadURL)
        }
    }

    func load(url: URL) throws -> (key: WebIconFontCacheKey, data: Data)? {
        let metadataURL = metadataURL(for: url.absoluteString)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        var decodedKey: WebIconFontCacheKey?
        do {
            let metadata = try JSONDecoder().decode(
                Metadata.self,
                from: Data(contentsOf: metadataURL)
            )
            decodedKey = metadata.key
            guard metadata.key.urlString == url.absoluteString else {
                throw WebIconFontFailure.cacheCorrupted
            }
            let data = try Data(contentsOf: payloadURL(for: metadata.key))
            guard metadata.key.validator.hasPrefix("etag:")
                || metadata.key.validator.hasPrefix("last-modified:")
                || metadata.key.validator == "sha256:\(Self.digestData(data))"
            else { throw WebIconFontFailure.cacheCorrupted }
            return (metadata.key, data)
        } catch {
            try? fileManager.removeItem(at: metadataURL)
            if let decodedKey {
                try? fileManager.removeItem(at: payloadURL(for: decodedKey))
            }
            throw error
        }
    }

    func remove(url: URL) throws {
        let metadataURL = metadataURL(for: url.absoluteString)
        if let payloadURL = existingPayloadURL(metadataURL: metadataURL) {
            try? fileManager.removeItem(at: payloadURL)
        }
        try? fileManager.removeItem(at: metadataURL)
    }

    private func metadataURL(for urlString: String) -> URL {
        root.appendingPathComponent(Self.digest(urlString) + ".json")
    }

    private func payloadURL(for key: WebIconFontCacheKey) -> URL {
        root.appendingPathComponent(Self.digest(key.urlString + "\n" + key.validator) + ".font")
    }

    private func existingPayloadURL(metadataURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return payloadURL(for: metadata.key)
    }

    private struct Metadata: Codable {
        let key: WebIconFontCacheKey
    }

    private static func digest(_ value: String) -> String {
        digestData(Data(value.utf8))
    }

    private static func digestData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
