/// A catalog image in a closed artwork family, never an arbitrary URL or path.
/// Unlike card-art lookup, the catalog names an exact file: no localization,
/// extension rewriting, or alternate-front fallback is permitted.
struct CatalogImageAsset: Sendable, Equatable, Hashable {
    let role: LocaleCatalogAssetRole
    let segments: [String]
    let format: AssetFormat

    init?(role: LocaleCatalogAssetRole, assetPath: String) {
        guard LocaleCatalogGrammar.isAssetPath(assetPath) else { return nil }
        let segments = assetPath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }),
              let root = segments.first, Self.roots(for: role).contains(root),
              let filename = segments.last,
              let dot = filename.lastIndex(of: "."), dot != filename.startIndex
        else { return nil }
        let format: AssetFormat
        switch filename[filename.index(after: dot)...] {
        case "png": format = .png
        case "jpg", "jpeg": format = .jpeg
        case "avif": format = .avif
        default: return nil
        }
        self.role = role
        self.segments = segments
        self.format = format
    }

    private static func roots(for role: LocaleCatalogAssetRole) -> Set<String> {
        switch role {
        case .encounterSet: ["encounter-sets"]
        case .card: ["cards"]
        case .token: ["tokens"]
        case .chaosToken: ["chaos-tokens"]
        case .campaign: ["campaigns"]
        case .homebrew: ["homebrew"]
        case .extra: ["extra"]
        // The catalog calls every other root "other". Only the remaining artwork
        // families already known to AssetLocator are representable, not any root.
        case .other: ["backs", "portraits", "sets", "boxes"]
        }
    }
}
