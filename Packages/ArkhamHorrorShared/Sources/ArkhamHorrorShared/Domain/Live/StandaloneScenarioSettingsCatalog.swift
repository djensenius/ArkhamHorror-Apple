import Foundation

/// Web-parity allow-list for `PickScenarioSettings` prompts whose static web scenario data
/// proves there is nothing for the player to configure. The web auto-submits `[]` only in
/// that case; the native client keeps an explicit Continue button but sends the same payload.
enum StandaloneScenarioSettingsCatalog {
    static let sourceRepository = "https://github.com/djensenius/ArkhamHorror"
    static let sourceCommit = "8453314123831e9fb1e7817e34190671b73b8ae0"

    /// Generated from `frontend/src/arkham/data/scenarios.ts` at `sourceCommit`, excluding
    /// homebrew entries, by collecting scenario ids whose merged static JSON has absent or
    /// empty `settings`.
    static let emptySettingsScenarioIDs: Set<String> = [
        "01104", "02041", "02062", "02118", "02159", "02195", "02236", "02274",
        "02311", "03043", "03061", "03120", "03159", "03200", "03240", "03274",
        "03316", "04043", "04054", "04113", "04161", "04205a", "04205b", "04237",
        "04277", "04314", "04344", "05043", "05050", "05065", "05120", "05161",
        "05197", "05284", "06039", "06063", "06168", "06206", "06247", "06286",
        "06333", "07041", "08501a", "09501", "09520", "09545", "09566", "09591",
        "09609", "09635", "09660", "09681", "09694", "10501", "10523", "10549",
        "10569", "10588", "10605", "10626", "10651", "10677a", "10679a", "10679b",
        "10704", "11501", "11517", "11536", "11553", "11587", "11612", "11639",
        "11673", "11682", "11688a", "12105", "12133", "12168", "13001", "13031",
        "13068", "70001", "71001", "72001", "81001", "82001", "83001", "84001",
        "85001", "86001", "87001", "88001", "90004", "90011", "90020", "90032",
        "90041", "90054", "90065", "90094",
    ]

    static func hasProvenEmptySettings(scenarioID: String?) -> Bool {
        guard let scenarioID else { return false }
        return emptySettingsScenarioIDs.contains(normalizedScenarioID(scenarioID))
    }

    private static func normalizedScenarioID(_ scenarioID: String) -> String {
        scenarioID.hasPrefix("c") ? String(scenarioID.dropFirst()) : scenarioID
    }
}
