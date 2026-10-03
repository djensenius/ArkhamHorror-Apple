import Foundation

func gameLifecycleLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}

func gameLifecycleLocalizedFormat(
    _ key: String,
    _ fallback: String,
    _ arguments: CVarArg...
) -> String {
    String(
        format: gameLifecycleLocalized(key, fallback),
        locale: Locale(identifier: Locale.current.identifier),
        arguments: arguments
    )
}

func gameLifecycleLocalizedPlural(
    count: Int,
    oneKey: String,
    oneFallback: String,
    manyKey: String,
    manyFallback: String
) -> String {
    if count == 1 {
        gameLifecycleLocalized(oneKey, oneFallback)
    } else {
        gameLifecycleLocalizedFormat(manyKey, manyFallback, count)
    }
}
