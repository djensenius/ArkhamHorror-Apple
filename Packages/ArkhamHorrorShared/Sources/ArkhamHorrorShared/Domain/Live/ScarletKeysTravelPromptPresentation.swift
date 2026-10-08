import Foundation

// swiftlint:disable nesting function_parameter_count
struct ScarletKeysTravelPromptPresentation: Sendable, Equatable {
    struct Location: Identifiable, Sendable, Equatable {
        let id: String
        let title: String?
        let subtitle: String?
        let travelTime: Int?
        let isAvailable: Bool
        let isCurrent: Bool
        let actions: [Action]

        var isActionable: Bool {
            title != nil && actions.contains(where: \.isActionable)
        }
    }

    struct Action: Identifiable, Sendable, Equatable {
        enum Kind: String, Sendable, Equatable, Hashable {
            case travel
            case travelVia
            case travelWithTicket
        }

        let locationID: String
        let locationTitle: String?
        let kind: Kind
        let title: String?
        let payload: JSONValue

        var id: String {
            "\(locationID).\(kind.rawValue)"
        }

        var isActionable: Bool {
            locationTitle != nil && title != nil
        }
    }

    let currentLocationID: String
    let hasTicket: Bool
    let travelTimeLabel: String?
    let locations: [Location]

    var actions: [Action] {
        locations.flatMap(\.actions)
    }
}

extension ScarletKeysTravelPromptPresentation {
    static let questionKey = "embark"

    private static let greenLocations = Set([
        "Arkham", "Cairo", "NewOrleans", "Venice", "MonteCarlo",
    ])

    static func supports(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation
    ) -> Bool {
        guard case .campaignSpecific = presentation.answer,
              presentation.questionKind == .pickCampaignSpecific,
              presentation.key == questionKey,
              let value = presentation.value,
              parseMap(value) != nil,
              rawQuestionIsEmbark(rawQuestion)
        else { return false }
        return true
    }

    static func labelRequests(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation?
    ) -> [(key: String, wireLabel: String)] {
        guard let presentation,
              supports(rawQuestion: rawQuestion, presentation: presentation),
              let value = presentation.value,
              let map = parseMap(value)
        else { return [] }
        var requests: [(key: String, wireLabel: String)] = [
            ("scarletKeysTravel.travelTime", "$scarletKeys.travelTime"),
            ("scarletKeysTravel.action.travel", "$scarletKeys.travelHere"),
            ("scarletKeysTravel.action.travelVia", "$scarletKeys.travelWithoutStopping"),
            (
                "scarletKeysTravel.action.travelWithTicket",
                "$scarletKeys.travelWithExpeditedTicket"
            ),
        ]
        requests += map.locationIDs.map { locationID in
            (
                "scarletKeysTravel.location.\(locationID).name",
                "$theScarletKeys.locations.\(locationID).name"
            )
        }
        requests += map.locationIDs.compactMap { locationID in
            guard locationIDHasSubtitle(locationID) else { return nil }
            return (
                "scarletKeysTravel.location.\(locationID).subtitle",
                "$theScarletKeys.locations.\(locationID).subtitle"
            )
        }
        return requests
    }

    static func make(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        labelResolutions: [String: BasicChoiceLabelResolution]
    ) -> ScarletKeysTravelPromptPresentation? {
        guard supports(rawQuestion: rawQuestion, presentation: presentation),
              let value = presentation.value,
              let map = parseMap(value)
        else { return nil }

        let isFinale = map.available.count == 1
        let travelTimeLabel = labelResolutions["scarletKeysTravel.travelTime"]?.title
        let locations = map.locationIDs.map { locationID in
            let isAvailable = map.available.contains(locationID)
            let isCurrent = locationID == map.current
            let rawTravelTime = map.travelTimes[locationID]
            let travelTime = displayedTravelTime(rawTravelTime, locationID: locationID)
            let title = labelResolutions[
                "scarletKeysTravel.location.\(locationID).name"
            ]?.title
            let actions = actions(
                for: locationID,
                locationTitle: title,
                isCurrent: isCurrent,
                isFinale: isFinale,
                isAvailable: isAvailable,
                hasTicket: map.hasTicket,
                travelTime: travelTime,
                labelResolutions: labelResolutions
            )
            return Location(
                id: locationID,
                title: title,
                subtitle: labelResolutions[
                    "scarletKeysTravel.location.\(locationID).subtitle"
                ]?.title,
                travelTime: travelTime,
                isAvailable: isAvailable,
                isCurrent: isCurrent,
                actions: actions
            )
        }
        return ScarletKeysTravelPromptPresentation(
            currentLocationID: map.current,
            hasTicket: map.hasTicket,
            travelTimeLabel: travelTimeLabel,
            locations: locations
        )
    }

    static func supportsSubmission(
        _ payload: JSONValue,
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        labelResolutions: [String: BasicChoiceLabelResolution]
    ) -> Bool {
        guard let prompt = make(
            rawQuestion: rawQuestion,
            presentation: presentation,
            labelResolutions: labelResolutions
        ) else { return false }
        return prompt.locations.contains { location in
            location.title != nil && location.actions.contains { action in
                action.isActionable && action.payload == payload
            }
        }
    }

    private static func actions(
        for locationID: String,
        locationTitle: String?,
        isCurrent: Bool,
        isFinale: Bool,
        isAvailable: Bool,
        hasTicket: Bool,
        travelTime: Int?,
        labelResolutions: [String: BasicChoiceLabelResolution]
    ) -> [Action] {
        if isCurrent && !isFinale {
            return []
        }
        var actions: [Action] = []
        if isAvailable || isCurrent {
            actions.append(action(
                .travel,
                locationID: locationID,
                locationTitle: locationTitle,
                labelResolutions: labelResolutions
            ))
            if hasTicket, (travelTime ?? 0) > 1 {
                actions.append(action(
                    .travelWithTicket,
                    locationID: locationID,
                    locationTitle: locationTitle,
                    labelResolutions: labelResolutions
                ))
            }
        }
        if !isCurrent {
            actions.append(action(
                .travelVia,
                locationID: locationID,
                locationTitle: locationTitle,
                labelResolutions: labelResolutions
            ))
        }
        return actions
    }

    private static func action(
        _ kind: Action.Kind,
        locationID: String,
        locationTitle: String?,
        labelResolutions: [String: BasicChoiceLabelResolution]
    ) -> Action {
        let wireTag = switch kind {
        case .travel: "travel"
        case .travelVia: "travelVia"
        case .travelWithTicket: "travelWithTicket"
        }
        return Action(
            locationID: locationID,
            locationTitle: locationTitle,
            kind: kind,
            title: labelResolutions["scarletKeysTravel.action.\(kind.rawValue)"]?.title,
            payload: .array([.string(wireTag), .string(locationID)])
        )
    }

    private static func displayedTravelTime(_ raw: Int?, locationID: String) -> Int? {
        if greenLocations.contains(locationID) {
            return (raw ?? 0) + 1
        }
        return raw
    }

    private static func rawQuestionIsEmbark(_ rawQuestion: JSONValue) -> Bool {
        guard let object = rawQuestion.objectValue,
              object["tag"]?.stringValue == "PickCampaignSpecific",
              let contents = object["contents"]?.arrayValue,
              contents.count == 2,
              contents[0].stringValue == questionKey
        else { return false }
        return parseMap(contents[1]) != nil
    }

    private static func parseMap(_ value: JSONValue) -> MapData? {
        guard let object = value.objectValue,
              let current = object["current"]?.stringValue,
              let hasTicket = object["hasTicket"]?.booleanValue,
              let available = object["available"]?.arrayValue?.compactMap(\.stringValue),
              let locations = object["locations"]?.arrayValue
        else { return nil }
        var locationIDs: [String] = []
        var travelTimes: [String: Int] = [:]
        for entry in locations {
            guard let pair = entry.arrayValue,
                  pair.count == 2,
                  let locationID = pair[0].stringValue,
                  let detail = pair[1].objectValue
            else { continue }
            locationIDs.append(locationID)
            travelTimes[locationID] = detail["travel"]?.integerValue
        }
        return MapData(
            current: current,
            hasTicket: hasTicket,
            available: Set(available),
            locationIDs: locationIDs,
            travelTimes: travelTimes
        )
    }

    private static func locationIDHasSubtitle(_ locationID: String) -> Bool {
        switch locationID {
        case "Alexandria", "Anchorage", "Bermuda", "Bombay", "BuenosAires",
             "Constantinople", "Havana", "Kabul", "Kathmandu", "Lagos",
             "Marrakesh", "Moscow", "Nairobi", "Perth", "RioDeJaneiro",
             "Rome", "SanFrancisco", "Shanghai", "Stockholm", "Sydney",
             "Tokyo", "YborCity":
            true
        default:
            false
        }
    }

    private struct MapData: Sendable, Equatable {
        let current: String
        let hasTicket: Bool
        let available: Set<String>
        let locationIDs: [String]
        let travelTimes: [String: Int]
    }
}

// swiftlint:enable nesting function_parameter_count

extension BasicChoicePromptPresentation {
    var scarletKeysTravelPrompt: ScarletKeysTravelPromptPresentation? {
        guard let presentation = semanticPresentation?.presentation else { return nil }
        return ScarletKeysTravelPromptPresentation.make(
            rawQuestion: identity.rawQuestion,
            presentation: presentation,
            labelResolutions: promptLabelResolutions
        )
    }
}
