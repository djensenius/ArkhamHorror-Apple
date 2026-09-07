import Foundation

/// The plural selector configured by the backend's governed Vue I18n 11.1.12 client.
///
/// `frontend/src/main.ts` supplies no custom `pluralRules`, so the runtime uses
/// `@intlify/core-base`'s `pluralDefault`: for two branches, zero selects the second branch,
/// one the first, and magnitudes above one the second; three or more branches select zero,
/// one, or the third branch respectively. The selected locale remains an explicit input
/// because links must continue from the locale that supplied their parent entry, and a future
/// governed catalog version may introduce locale-specific rules rather than silently
/// inheriting this one.
enum LocaleCatalogPluralRules {
    static func select(
        variables: JSONValue,
        caseCount: Int,
        locale: String
    ) -> Result<Int, StoryUnavailableReason> {
        guard caseCount >= 2, LocaleCatalogGrammar.isCatalogLocaleTag(locale) else {
            return .failure(.unsupportedEntry)
        }
        guard case let .object(named) = variables else {
            return .failure(.missingVariable)
        }
        guard let selector = named["count"] ?? named["n"] else {
            return .failure(.missingVariable)
        }
        guard case let .number(number) = selector else {
            return .failure(.unsupportedVariableValue)
        }
        return select(number: number, caseCount: caseCount)
    }

    private static func select(
        number: JSONNumber, caseCount: Int
    ) -> Result<Int, StoryUnavailableReason> {
        guard let magnitude = number.wholeNumberMagnitude else {
            return .failure(.unsupportedVariableValue)
        }
        if caseCount == 2 {
            return .success(magnitude == "1" ? 0 : 1)
        }
        if magnitude == "0" {
            return .success(0)
        }
        return .success(magnitude == "1" ? 1 : 2)
    }
}
