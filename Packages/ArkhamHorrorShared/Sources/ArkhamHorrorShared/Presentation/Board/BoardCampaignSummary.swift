import Foundation

/// Campaign hand-off presentation data copied from the authoritative server snapshot.
///
/// This is display-only: it keeps campaign-log keys/values, investigator progression,
/// and the server's resolution markers raw so renderers can resolve catalog-backed text
/// against the currently loaded locale and card catalogs.
struct BoardCampaignSummary: Sendable, Equatable {
    let resolutions: [BoardCampaignResolutionSummary]
    let log: BoardCampaignLogSummary
    let investigators: [BoardCampaignInvestigatorProgress]

    var latestResolution: BoardCampaignResolutionSummary? {
        resolutions.last
    }

    var isEmpty: Bool {
        resolutions.isEmpty && log.isEmpty && investigators.isEmpty
    }
}

struct BoardCampaignResolutionSummary: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case campaign(scenarioID: String, resolution: JSONValue)
        case resolvedStory(JSONValue)
    }

    let source: Source

    func title(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        switch source {
        case let .campaign(_, resolution):
            BoardCampaignSummaryFormatting.resolutionTitle(resolution, context: context)
        case .resolvedStory:
            context.localization.localized("campaign.summary.resolvedStory", "Resolved story")
        }
    }

    func detail(context: BoardCampaignSummaryDisplayContext = .system) -> String? {
        switch source {
        case let .campaign(scenarioID, _):
            BoardCampaignSummaryFormatting.scenarioTitle(scenarioID, context: context)
        case let .resolvedStory(story):
            BoardCampaignSummaryFormatting.jsonDisplayValue(story, context: context)
        }
    }
}

struct BoardCampaignLogSummary: Sendable, Equatable {
    let entries: [BoardCampaignLogEntry]
    let counts: [BoardCampaignLogCount]
    let recordedSets: [BoardCampaignLogRecordedSet]

    var isEmpty: Bool {
        entries.isEmpty && counts.isEmpty && recordedSets.isEmpty
    }
}

struct BoardCampaignLogEntry: Sendable, Equatable, Identifiable {
    let id: String
    let key: JSONValue
    let isCrossedOut: Bool

    func title(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        BoardCampaignSummaryFormatting.logKeyTitle(key, context: context)
    }

    func accessibilityTitle(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        let title = title(context: context)
        guard isCrossedOut else { return title }
        return String(
            format: context.localization.localized(
                "campaign.between.log.value.crossedOut.accessibility",
                "%@, crossed out"
            ),
            title
        )
    }
}

struct BoardCampaignLogCount: Sendable, Equatable, Identifiable {
    let id: String
    let key: JSONValue
    let value: Int

    func title(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        BoardCampaignSummaryFormatting.logKeyTitle(key, context: context)
    }
}

struct BoardCampaignLogRecordedSet: Sendable, Equatable, Identifiable {
    let id: String
    let key: JSONValue
    let values: [BoardCampaignLogRecordedValue]

    func title(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        BoardCampaignSummaryFormatting.logKeyTitle(key, context: context)
    }
}

struct BoardCampaignLogRecordedValue: Sendable, Equatable, Identifiable {
    let id: String
    let recordType: String?
    let value: JSONValue
    let isCrossedOut: Bool
    let isCircled: Bool

    func title(context: BoardCampaignSummaryDisplayContext = .system) -> String {
        BoardCampaignSummaryFormatting.recordedValueTitle(
            value, recordType: recordType, context: context
        )
    }
}

struct BoardCampaignInvestigatorProgress: Sendable, Equatable, Identifiable {
    let id: InvestigatorID
    let displayName: String
    let experiencePoints: Int
    let spentExperience: Int
    let availableExperience: Int
    let physicalTrauma: Int
    let mentalTrauma: Int
    let killed: Bool
    let drivenInsane: Bool
}

enum BoardCampaignSummaryBuilder {
    private struct RecordedValueRaw {
        let value: JSONValue
        let isCrossedOut: Bool
        let isCircled: Bool
    }

    static func makeSummary(
        campaign: JSONValue?,
        scenario: Scenario?,
        investigators: [BoardInvestigatorNode]
    ) -> BoardCampaignSummary? {
        let log = makeLogSummary(campaign: campaign, scenario: scenario)
        let progress = investigators.map { investigator in
            BoardCampaignInvestigatorProgress(
                id: investigator.id,
                displayName: investigator.displayName,
                experiencePoints: investigator.experiencePoints,
                spentExperience: investigator.spentExperience,
                availableExperience: investigator.availableExperience,
                physicalTrauma: investigator.physicalTrauma,
                mentalTrauma: investigator.mentalTrauma,
                killed: investigator.killed,
                drivenInsane: investigator.drivenInsane
            )
        }
        let summary = BoardCampaignSummary(
            resolutions: makeResolutions(campaign: campaign, scenario: scenario),
            log: log,
            investigators: progress
        )
        return summary.isEmpty ? nil : summary
    }

    static func makeLogSummary(
        campaign: JSONValue?,
        scenario: Scenario?
    ) -> BoardCampaignLogSummary {
        if let log = campaign?.objectValue?["log"] {
            return makeLogSummary(from: log)
        }
        if let scenario {
            return makeLogSummary(from: scenario.standaloneCampaignLog)
        }
        return BoardCampaignLogSummary(entries: [], counts: [], recordedSets: [])
    }

    static func makeLogSummary(from log: ScenarioCampaignLog) -> BoardCampaignLogSummary {
        makeLogSummary(
            recorded: log.recorded,
            crossedOut: log.crossedOut,
            recordedCounts: log.recordedCounts,
            recordedSets: log.recordedSets
        )
    }

    static func makeLogSummary(from log: JSONValue) -> BoardCampaignLogSummary {
        guard let object = log.objectValue else {
            return BoardCampaignLogSummary(entries: [], counts: [], recordedSets: [])
        }
        return makeLogSummary(
            recorded: object["recorded"]?.arrayValue ?? [],
            crossedOut: object["crossedOut"]?.arrayValue ?? [],
            recordedCounts: object["recordedCounts"]?.arrayValue ?? [],
            recordedSets: object["recordedSets"]?.arrayValue ?? []
        )
    }

    private static func makeLogSummary(
        recorded: [JSONValue],
        crossedOut: [JSONValue],
        recordedCounts: [JSONValue],
        recordedSets: [JSONValue]
    ) -> BoardCampaignLogSummary {
        let crossedOutIDs = Set(crossedOut.map(BoardCampaignSummaryFormatting.logKeyIdentity))
        let entries: [BoardCampaignLogEntry] = recorded.compactMap { key in
            guard shouldShowRecordedKey(key) else { return nil }
            let id = BoardCampaignSummaryFormatting.logKeyIdentity(key)
            return BoardCampaignLogEntry(id: id, key: key, isCrossedOut: crossedOutIDs.contains(id))
        }

        let counts = recordedCounts.compactMap(parseCount)
        let sets = recordedSets.compactMap(parseRecordedSet)
        return BoardCampaignLogSummary(entries: entries, counts: counts, recordedSets: sets)
    }

    private static func shouldShowRecordedKey(_ value: JSONValue) -> Bool {
        guard let object = value.objectValue else { return true }
        let hiddenTags = ["Teachings1", "Teachings2", "Teachings3"]
        if let tag = object["tag"]?.stringValue, hiddenTags.contains(tag) {
            return false
        }
        return !isSectionKey(value)
    }

    private static func isSectionKey(_ value: JSONValue) -> Bool {
        guard let contents = value.objectValue?["contents"]?.objectValue else { return false }
        return contents["tag"]?.stringValue != nil && contents["contents"]?.stringValue != nil
    }

    private static func parseCount(_ value: JSONValue) -> BoardCampaignLogCount? {
        guard case let .array(pair) = value,
              pair.count == 2,
              !isSectionKey(pair[0]),
              let count = pair[1].integerValue
        else { return nil }
        return BoardCampaignLogCount(
            id: BoardCampaignSummaryFormatting.logKeyIdentity(pair[0]),
            key: pair[0],
            value: count
        )
    }

    private static func parseRecordedSet(_ value: JSONValue) -> BoardCampaignLogRecordedSet? {
        guard case let .array(pair) = value,
              pair.count == 2,
              case let .array(records) = pair[1]
        else { return nil }
        let keyID = BoardCampaignSummaryFormatting.logKeyIdentity(pair[0])
        guard !keyID.lowercased().contains("discoveredglyph") else { return nil }
        let values = records.enumerated().map { index, record in
            parseRecordedValue(record, idPrefix: keyID, index: index)
        }
        return BoardCampaignLogRecordedSet(id: keyID, key: pair[0], values: values)
    }

    private static func parseRecordedValue(
        _ value: JSONValue,
        idPrefix: String,
        index: Int
    ) -> BoardCampaignLogRecordedValue {
        let recordType = value.objectValue?["recordType"]?.stringValue
        let recordValue = value.objectValue?["recordVal"] ?? value
        let unwrapped = unwrapRecordedValue(recordValue)
        return BoardCampaignLogRecordedValue(
            id: "\(idPrefix):\(index)",
            recordType: recordType,
            value: unwrapped.value,
            isCrossedOut: unwrapped.isCrossedOut,
            isCircled: unwrapped.isCircled
        )
    }

    private static func unwrapRecordedValue(_ value: JSONValue) -> RecordedValueRaw {
        guard let object = value.objectValue,
              let tag = object["tag"]?.stringValue,
              let contents = object["contents"]
        else {
            return RecordedValueRaw(value: value, isCrossedOut: false, isCircled: false)
        }
        switch tag {
        case "Recorded":
            return RecordedValueRaw(
                value: contents,
                isCrossedOut: false,
                isCircled: object["circled"]?.booleanValue ?? false
            )
        case "CrossedOut":
            return RecordedValueRaw(
                value: contents,
                isCrossedOut: true,
                isCircled: object["circled"]?.booleanValue ?? false
            )
        default:
            return RecordedValueRaw(
                value: value,
                isCrossedOut: false,
                isCircled: object["circled"]?.booleanValue ?? false
            )
        }
    }

    private static func makeResolutions(
        campaign: JSONValue?,
        scenario: Scenario?
    ) -> [BoardCampaignResolutionSummary] {
        let orderedCampaignResolutions = campaign.map(campaignResolutions) ?? []
        if !orderedCampaignResolutions.isEmpty {
            return orderedCampaignResolutions
        }
        guard let scenario,
              scenario.inResolution,
              let story = scenario.resolvedStories.last
        else { return [] }
        return [BoardCampaignResolutionSummary(source: .resolvedStory(story))]
    }

    private static func campaignResolutions(
        _ campaign: JSONValue
    ) -> [BoardCampaignResolutionSummary] {
        guard let object = campaign.objectValue,
              let resolutions = object["resolutions"]?.objectValue,
              !resolutions.isEmpty
        else { return [] }

        let orderedScenarioIDs = scenarioStepIDs(in: object["completedSteps"])
        var orderedEntries: [(key: String, value: JSONValue)] = []
        var consumedKeys = Set<String>()
        for scenarioID in orderedScenarioIDs {
            guard let entry = resolutionEntry(for: scenarioID, in: resolutions),
                  !consumedKeys.contains(entry.key)
            else { continue }
            orderedEntries.append(entry)
            consumedKeys.insert(entry.key)
        }

        for key in resolutions.keys.sorted() where !consumedKeys.contains(key) {
            if let value = resolutions[key] {
                orderedEntries.append((key: key, value: value))
            }
        }

        return orderedEntries.map { entry in
            BoardCampaignResolutionSummary(source: .campaign(
                scenarioID: entry.key,
                resolution: entry.value
            ))
        }
    }

    private static func resolutionEntry(
        for scenarioID: String,
        in resolutions: [String: JSONValue]
    ) -> (key: String, value: JSONValue)? {
        let candidates = scenarioID.hasPrefix("c")
            ? [scenarioID, String(scenarioID.dropFirst())]
            : [scenarioID, "c\(scenarioID)"]
        for candidate in candidates {
            if let value = resolutions[candidate] {
                return (key: candidate, value: value)
            }
        }
        return nil
    }

    private static func scenarioStepIDs(in completedSteps: JSONValue?) -> [String] {
        guard let steps = completedSteps?.arrayValue else { return [] }
        return steps.compactMap { step -> String? in
            guard let object = step.objectValue,
                  let tag = object["tag"]?.stringValue,
                  [
                      "ScenarioStep",
                      "ScenarioStepWithOptions",
                      "StandaloneScenarioStep",
                      "StandaloneScenarioStepWithOptions",
                  ].contains(tag)
            else { return nil }
            if let contents = object["contents"]?.stringValue {
                return contents
            }
            if let contents = object["contents"]?.arrayValue?.first?.stringValue {
                return contents
            }
            return nil
        }
    }
}
