import Foundation

// swiftlint:disable file_length

/// Campaign hand-off presentation data copied from the authoritative server snapshot.
///
/// This is display-only: it formats campaign-log keys/values, investigator progression,
/// and the server's latest resolution marker without evaluating campaign rules or deck
/// legality on the client.
struct BoardCampaignSummary: Sendable, Equatable {
    let latestResolution: BoardCampaignResolutionSummary?
    let log: BoardCampaignLogSummary
    let investigators: [BoardCampaignInvestigatorProgress]

    var isEmpty: Bool {
        latestResolution == nil && log.isEmpty && investigators.isEmpty
    }
}

struct BoardCampaignResolutionSummary: Sendable, Equatable {
    let title: String
    let detail: String?
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
    let title: String
    let isCrossedOut: Bool
}

struct BoardCampaignLogCount: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: Int
}

struct BoardCampaignLogRecordedSet: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let values: [BoardCampaignLogRecordedValue]
}

struct BoardCampaignLogRecordedValue: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let isCrossedOut: Bool
    let isCircled: Bool
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

// swiftlint:disable:next type_body_length
enum BoardCampaignSummaryBuilder {
    private struct RecordedValueDisplay {
        let title: String
        let isCrossedOut: Bool
        let isCircled: Bool
    }

    static func makeSummary(
        campaign: JSONValue?,
        scenario: Scenario?,
        investigators: [BoardInvestigatorNode],
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> BoardCampaignSummary? {
        let log = makeLogSummary(campaign: campaign, scenario: scenario, context: context)
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
            latestResolution: makeLatestResolution(
                campaign: campaign, scenario: scenario, context: context
            ),
            log: log,
            investigators: progress
        )
        return summary.isEmpty ? nil : summary
    }

    static func makeLogSummary(
        campaign: JSONValue?,
        scenario: Scenario?,
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> BoardCampaignLogSummary {
        if let log = campaign?.objectValue?["log"] {
            return makeLogSummary(from: log, context: context)
        }
        if let scenario {
            return makeLogSummary(from: scenario.standaloneCampaignLog, context: context)
        }
        return BoardCampaignLogSummary(entries: [], counts: [], recordedSets: [])
    }

    static func makeLogSummary(
        from log: ScenarioCampaignLog,
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> BoardCampaignLogSummary {
        makeLogSummary(
            recorded: log.recorded,
            crossedOut: log.crossedOut,
            recordedCounts: log.recordedCounts,
            recordedSets: log.recordedSets,
            context: context
        )
    }

    static func makeLogSummary(
        from log: JSONValue,
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> BoardCampaignLogSummary {
        guard let object = log.objectValue else {
            return BoardCampaignLogSummary(entries: [], counts: [], recordedSets: [])
        }
        return makeLogSummary(
            recorded: object["recorded"]?.arrayValue ?? [],
            crossedOut: object["crossedOut"]?.arrayValue ?? [],
            recordedCounts: object["recordedCounts"]?.arrayValue ?? [],
            recordedSets: object["recordedSets"]?.arrayValue ?? [],
            context: context
        )
    }

    private static func makeLogSummary(
        recorded: [JSONValue],
        crossedOut: [JSONValue],
        recordedCounts: [JSONValue],
        recordedSets: [JSONValue],
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignLogSummary {
        let crossedOutIDs = Set(crossedOut.map(BoardCampaignSummaryFormatting.logKeyIdentity))
        let entries: [BoardCampaignLogEntry] = recorded.compactMap { key in
            guard shouldShowRecordedKey(key) else { return nil }
            let id = BoardCampaignSummaryFormatting.logKeyIdentity(key)
            return BoardCampaignLogEntry(
                id: id,
                title: BoardCampaignSummaryFormatting.logKeyTitle(key, context: context),
                isCrossedOut: crossedOutIDs.contains(id)
            )
        }

        let counts = recordedCounts.compactMap { parseCount($0, context: context) }
        let sets = recordedSets.compactMap { parseRecordedSet($0, context: context) }
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

    private static func parseCount(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignLogCount? {
        guard case let .array(pair) = value,
              pair.count == 2,
              !isSectionKey(pair[0]),
              let count = pair[1].integerValue
        else { return nil }
        return BoardCampaignLogCount(
            id: BoardCampaignSummaryFormatting.logKeyIdentity(pair[0]),
            title: BoardCampaignSummaryFormatting.logKeyTitle(pair[0], context: context),
            value: count
        )
    }

    private static func parseRecordedSet(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignLogRecordedSet? {
        guard case let .array(pair) = value,
              pair.count == 2,
              case let .array(records) = pair[1]
        else { return nil }
        let keyID = BoardCampaignSummaryFormatting.logKeyIdentity(pair[0])
        guard !keyID.lowercased().contains("discoveredglyph") else { return nil }
        let values = records.enumerated().map { index, record in
            parseRecordedValue(record, idPrefix: keyID, index: index, context: context)
        }
        return BoardCampaignLogRecordedSet(
            id: keyID,
            title: BoardCampaignSummaryFormatting.logKeyTitle(pair[0], context: context),
            values: values
        )
    }

    private static func parseRecordedValue(
        _ value: JSONValue,
        idPrefix: String,
        index: Int,
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignLogRecordedValue {
        let recordType = value.objectValue?["recordType"]?.stringValue
        let recordValue = value.objectValue?["recordVal"] ?? value
        let unwrapped = unwrapRecordedValue(recordValue, recordType: recordType, context: context)
        return BoardCampaignLogRecordedValue(
            id: "\(idPrefix):\(index):\(unwrapped.title)",
            title: unwrapped.title,
            isCrossedOut: unwrapped.isCrossedOut,
            isCircled: unwrapped.isCircled
        )
    }

    private static func unwrapRecordedValue(
        _ value: JSONValue,
        recordType: String?,
        context: BoardCampaignSummaryDisplayContext
    ) -> RecordedValueDisplay {
        guard let object = value.objectValue,
              let tag = object["tag"]?.stringValue,
              let contents = object["contents"]
        else {
            return RecordedValueDisplay(
                title: recordedContentsTitle(value, recordType: recordType, context: context),
                isCrossedOut: false,
                isCircled: false
            )
        }
        let inner = recordedContentsTitle(contents, recordType: recordType, context: context)
        switch tag {
        case "Recorded":
            return RecordedValueDisplay(
                title: inner,
                isCrossedOut: false,
                isCircled: object["circled"]?.boolValue ?? false
            )
        case "CrossedOut":
            return RecordedValueDisplay(
                title: inner,
                isCrossedOut: true,
                isCircled: object["circled"]?.boolValue ?? false
            )
        default:
            return RecordedValueDisplay(
                title: BoardCampaignSummaryFormatting.jsonDisplayValue(value, context: context),
                isCrossedOut: false,
                isCircled: object["circled"]?.boolValue ?? false
            )
        }
    }

    private static func recordedContentsTitle(
        _ value: JSONValue,
        recordType: String?,
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        if recordType == "RecordableCardCode" {
            if let title = cardDisplayName(value, context: context) {
                return title
            }
        }
        if let recordType, recordType != "RecordableCardCode", let text = value.stringValue {
            return BoardCampaignSummaryFormatting.splitCamelCase(text)
        }
        if recordType == nil, let title = cardDisplayName(value, context: context) {
            return title
        }
        return BoardCampaignSummaryFormatting.jsonDisplayValue(value, context: context)
    }

    private static func cardDisplayName(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext
    ) -> String? {
        guard let code = value.stringValue else { return nil }
        return BoardCampaignSummaryFormatting.cardDisplayName(for: code, context: context)
    }

    private static func makeLatestResolution(
        campaign: JSONValue?,
        scenario: Scenario?,
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignResolutionSummary? {
        if let resolution = campaign.flatMap({ latestCampaignResolution($0, context: context) }) {
            return resolution
        }
        guard let scenario,
              scenario.inResolution,
              let story = scenario.resolvedStories.last
        else { return nil }
        return BoardCampaignResolutionSummary(
            title: context.localization.localized(
                "campaign.summary.resolvedStory", "Resolved story"
            ),
            detail: BoardCampaignSummaryFormatting.jsonDisplayValue(story, context: context)
        )
    }

    private static func latestCampaignResolution(
        _ campaign: JSONValue,
        context: BoardCampaignSummaryDisplayContext
    ) -> BoardCampaignResolutionSummary? {
        guard let object = campaign.objectValue,
              let resolutions = object["resolutions"]?.objectValue,
              !resolutions.isEmpty
        else { return nil }
        let latestScenarioID = latestScenarioStepID(in: object["completedSteps"])
        let entry = latestScenarioID.flatMap { scenarioID in
            resolutions.first { key, _ in key == scenarioID || key == "c\(scenarioID)" }
        } ?? resolutions.max { $0.key < $1.key }
        guard let entry else { return nil }
        return BoardCampaignResolutionSummary(
            title: resolutionTitle(entry.value, context: context),
            detail: scenarioTitle(entry.key, context: context)
        )
    }

    private static func latestScenarioStepID(in completedSteps: JSONValue?) -> String? {
        guard let steps = completedSteps?.arrayValue else { return nil }
        return steps.reversed().compactMap { step -> String? in
            guard let object = step.objectValue,
                  let tag = object["tag"]?.stringValue,
                  tag == "ScenarioStep" || tag == "ScenarioStepWithOptions"
            else { return nil }
            if let contents = object["contents"]?.stringValue {
                return contents
            }
            if let contents = object["contents"]?.arrayValue?.first?.stringValue {
                return contents
            }
            return nil
        }.first
    }

    private static func resolutionTitle(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        let isNoResolution = value.stringValue == "NoResolution"
            || value.objectValue?["tag"]?.stringValue == "NoResolution"
        if isNoResolution {
            return context.localization.localized("campaign.summary.noResolution", "No resolution")
        }
        if let object = value.objectValue {
            let isResolution = object["tag"]?.stringValue == "Resolution"
            if isResolution, let number = object["contents"]?.integerValue {
                return localizedResolutionNumber(number, context: context)
            }
        }
        if let number = value.integerValue {
            return localizedResolutionNumber(number, context: context)
        }
        return BoardCampaignSummaryFormatting.jsonDisplayValue(value, context: context)
    }

    private static func localizedResolutionNumber(
        _ number: Int,
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        String(
            format: context.localization.localized(
                "campaign.summary.resolutionNumber", "Resolution %d"
            ),
            number
        )
    }

    private static func scenarioTitle(
        _ key: String,
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        if let title = BoardCampaignSummaryFormatting.cardDisplayName(for: key, context: context) {
            return title
        }
        return BoardCampaignSummaryFormatting.titleizedWords(key)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self,
              let magnitude = value.wholeNumberMagnitude,
              let int64 = Int64(magnitude)
        else { return nil }
        let signed = value.sign == .minus ? -int64 : int64
        return Int(exactly: signed)
    }
}
