import Foundation

extension SecureCacheDirectory {
    /// Production remains under Caches. Home and temporary anchors also
    /// support unsandboxed macOS development/tests; in shipped sandboxed
    /// apps FileManager supplies locations inside the app container.
    /// Never infer an anchor from a caller's arbitrary cache URL.
    static func cacheTrustAnchors(for directory: URL, fileManager: FileManager) throws -> [URL] {
        #if os(macOS)
            let home = fileManager.homeDirectoryForCurrentUser
        #else
            // FileManager's home property is unavailable on iOS-family SDKs.
            // Foundation supplies the app's data-container root instead.
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
        let anchors = (fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            + [home, fileManager.temporaryDirectory]).filter {
            (try? cacheRelativeComponents(of: directory, below: $0)) != nil
        }
        guard !anchors.isEmpty else {
            throw AssetError.cachePersistenceFailed(
                "Cache directory is outside the trusted app locations"
            )
        }
        return anchors
    }

    /// Purely lexical containment: no stat, readlink, or symlink resolution
    /// may inspect paths above the anchor. Component comparison (not string
    /// prefix matching) excludes siblings, the anchor itself, and escapes.
    static func cacheRelativeComponents(of directory: URL, below anchor: URL) throws -> [String] {
        let path = try cachePathComponents(directory)
        let root = try cachePathComponents(anchor)
        guard !root.isEmpty, path.count > root.count, path.starts(with: root) else {
            throw AssetError
                .cachePersistenceFailed("Cache directory must be below its trust anchor")
        }
        return Array(path.dropFirst(root.count))
    }

    private static func cachePathComponents(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw AssetError.cachePersistenceFailed("Cache location must be an absolute file URL")
        }
        var components: [String] = []
        for component in url.path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default: components.append(String(component))
            }
        }
        // Darwin's fixed compatibility spellings can differ between two
        // FileManager URLs (/var vs /private/var, notably on iOS-family
        // devices). Normalize only these top-level names, lexically. They
        // lie above the trusted anchor; never lstat/readlink them or resolve
        // arbitrary symlinks within the descriptor-relative walked segment.
        if let first = components.first, ["tmp", "var", "etc"].contains(first) {
            components.insert("private", at: 0)
        }
        return components
    }
}
