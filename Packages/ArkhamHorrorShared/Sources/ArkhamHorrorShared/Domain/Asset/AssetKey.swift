/// A fully-typed descriptor for a single requested asset.
///
/// This is the only way to describe "the image I want" anywhere in this
/// feature: there is no API that accepts an arbitrary relative path or URL.
/// ``AssetLocator`` turns a key into an ordered, deterministic candidate
/// list; ``AssetCacheService`` folds the key's ``source`` namespace,
/// ``category``, and locale into the disk cache key so hosted and
/// self-hosted deployments can never collide.
struct AssetKey: Sendable, Equatable, Hashable {
    /// The canonical CDN origin this key resolves against.
    let source: AssetSourceNamespace
    let category: AssetCategory
    /// The caller's requested locale. Ignored for categories where
    /// ``AssetCategory/isLocalizable`` is `false`.
    let locale: AssetLocale

    init(
        source: AssetSourceNamespace = .hosted,
        category: AssetCategory,
        locale: AssetLocale = .english
    ) {
        self.source = source
        self.category = category
        self.locale = locale
    }

    /// The image format expected for this key's category, independent of
    /// which fallback candidate ultimately resolves.
    var expectedFormat: AssetFormat {
        category.expectedFormat
    }
}
