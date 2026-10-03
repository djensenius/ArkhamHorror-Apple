import Foundation

enum BoardLocalization {
    static func localized(_ key: String, _ fallback: String) -> String {
        CampaignPromptLocalization.localized(key, fallback)
    }

    static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key, fallback), arguments: arguments)
    }
}
