import Foundation

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

enum BoardCampaignSummaryBuilder {
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
            latestResolution: makeLatestResolution(campaign: campaign, scenario: scenario),
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
        let crossedOutIDs = Set(crossedOut.map(logKeyIdentity))
        var seenEntryIDs = Set<String>()
        var entries: [BoardCampaignLogEntry] = recorded.map { key in
            let id = logKeyIdentity(key)
            seenEntryIDs.insert(id)
            return BoardCampaignLogEntry(
                id: id,
                title: logKeyTitle(key),
                isCrossedOut: crossedOutIDs.contains(id)
            )
        }
        entries.append(contentsOf: crossedOut.compactMap { key in
            let id = logKeyIdentity(key)
            guard !seenEntryIDs.contains(id) else { return nil }
            return BoardCampaignLogEntry(id: id, title: logKeyTitle(key), isCrossedOut: true)
        })

        let counts = recordedCounts.compactMap(parseCount)
        let sets = recordedSets.compactMap(parseRecordedSet)
        return BoardCampaignLogSummary(entries: entries, counts: counts, recordedSets: sets)
    }

    private static func parseCount(_ value: JSONValue) -> BoardCampaignLogCount? {
        guard case let .array(pair) = value,
              pair.count == 2,
              let count = pair[1].integerValue
        else { return nil }
        return BoardCampaignLogCount(
            id: logKeyIdentity(pair[0]),
            title: logKeyTitle(pair[0]),
            value: count
        )
    }

    private static func parseRecordedSet(_ value: JSONValue) -> BoardCampaignLogRecordedSet? {
        guard case let .array(pair) = value,
              pair.count == 2,
              case let .array(records) = pair[1]
        else { return nil }
        let keyID = logKeyIdentity(pair[0])
        let values = records.enumerated().map { index, record in
            parseRecordedValue(record, idPrefix: keyID, index: index)
        }
        return BoardCampaignLogRecordedSet(
            id: keyID,
            title: logKeyTitle(pair[0]),
            values: values
        )
    }

    private static func parseRecordedValue(
        _ value: JSONValue,
        idPrefix: String,
        index: Int
    ) -> BoardCampaignLogRecordedValue {
        let recordValue = value.objectValue?["recordVal"] ?? value
        let unwrapped = unwrapRecordedValue(recordValue)
        return BoardCampaignLogRecordedValue(
            id: "\(idPrefix):\(index):\(unwrapped.title)",
            title: unwrapped.title,
            isCrossedOut: unwrapped.isCrossedOut,
            isCircled: unwrapped.isCircled
        )
    }

    private static func unwrapRecordedValue(
        _ value: JSONValue
    ) -> (title: String, isCrossedOut: Bool, isCircled: Bool) {
        guard let object = value.objectValue,
              let tag = object["tag"]?.stringValue,
              let contents = object["contents"]
        else {
            return (jsonDisplayValue(value), false, false)
        }
        let inner = jsonDisplayValue(contents)
        switch tag {
        case "Recorded":
            return (inner, false, object["circled"]?.boolValue ?? false)
        case "CrossedOut":
            return (inner, true, object["circled"]?.boolValue ?? false)
        default:
            return (jsonDisplayValue(value), false, object["circled"]?.boolValue ?? false)
        }
    }

    private static func makeLatestResolution(
        campaign: JSONValue?,
        scenario: Scenario?
    ) -> BoardCampaignResolutionSummary? {
        if let campaign,
           let resolution = latestCampaignResolution(campaign)
        {
            return resolution
        }
        guard let scenario,
              scenario.inResolution,
              let story = scenario.resolvedStories.last
        else { return nil }
        return BoardCampaignResolutionSummary(
            title: titleizedWords("resolvedStory"),
            detail: jsonDisplayValue(story)
        )
    }

    private static func latestCampaignResolution(_ campaign: JSONValue) -> BoardCampaignResolutionSummary? {
        guard let object = campaign.objectValue,
              let resolutions = object["resolutions"]?.objectValue,
              !resolutions.isEmpty
        else { return nil }
        let latestScenarioID = latestScenarioStepID(in: object["completedSteps"])
        let entry = latestScenarioID.flatMap { scenarioID in
            resolutions.first { key, _ in key == scenarioID || key == "c\(scenarioID)" }
        } ?? resolutions.sorted { $0.key < $1.key }.last
        guard let entry else { return nil }
        return BoardCampaignResolutionSummary(
            title: resolutionTitle(entry.value),
            detail: titleizedWords(entry.key)
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

    private static func resolutionTitle(_ value: JSONValue) -> String {
        if value.stringValue == "NoResolution" {
            return titleizedWords("noResolution")
        }
        if let object = value.objectValue,
           object["tag"]?.stringValue == "Resolution",
           let number = object["contents"]?.integerValue
        {
            return "Resolution \(number)"
        }
        if let number = value.integerValue {
            return "Resolution \(number)"
        }
        return jsonDisplayValue(value)
    }

    private static func logKeyIdentity(_ value: JSONValue) -> String {
        formatLogKey(value) ?? jsonDisplayValue(value)
    }

    private static func logKeyTitle(_ value: JSONValue) -> String {
        titleizedWords(formatLogKey(value) ?? jsonDisplayValue(value))
    }

    private static func formatLogKey(_ value: JSONValue) -> String? {
        guard let object = value.objectValue,
              let tag = object["tag"]?.stringValue
        else { return nil }
        let prefix = lowerFirst(tag.replacingOccurrences(of: "Key", with: ""))
        guard let contents = object["contents"] else {
            return "base.key.\(lowerFirst(tag))"
        }
        if let nested = contents.objectValue,
           let nestedTag = nested["tag"]?.stringValue
        {
            let section = lowerFirst(nestedTag)
            if let nestedContents = nested["contents"]?.stringValue {
                return "\(prefix).key['[\(section)]'].\(lowerFirst(nestedContents))"
            }
            return "\(prefix).key.\(section)"
        }
        if let text = contents.stringValue {
            return "\(prefix).key.\(lowerFirst(text))"
        }
        return "\(prefix).key.unknown"
    }

    private static func jsonDisplayValue(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "—"
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(number):
            return number.description
        case let .string(value):
            return titleizedWords(value)
        case let .array(values):
            return values.map(jsonDisplayValue).joined(separator: ", ")
        case let .object(object):
            if let title = object["title"]?.stringValue {
                return title
            }
            if let name = object["name"]?.stringValue {
                return name
            }
            if let tag = object["tag"]?.stringValue,
               let contents = object["contents"]
            {
                return "\(titleizedWords(tag)): \(jsonDisplayValue(contents))"
            }
            if let tag = object["tag"]?.stringValue {
                return titleizedWords(tag)
            }
            return titleizedWords(object.keys.sorted().joined(separator: ", "))
        }
    }

    private static func lowerFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }

    private static func titleizedWords(_ value: String) -> String {
        let leaf = value
            .replacingOccurrences(of: "'", with: "")
            .split(separator: ".")
            .last
            .map(String.init) ?? value
        let cleaned = leaf
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let pattern = #"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        let words = regex?.matches(in: cleaned, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: cleaned) else { return nil }
            return String(cleaned[range]).lowercased()
        } ?? cleaned.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return value }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
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
