// swiftlint:disable file_length function_body_length cyclomatic_complexity line_length
import Foundation

extension QuestionPresentation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion
        case questionVersion
        case questionKind
        case choiceCount
        case choices
        case answer
        case selection
        case groups
        case label
        case questionLabel
        case completionLabel
        case confirmLabel
        case backLabel
        case cardCode
        case payCost
        case questionSource
        case tooltip
        case flavorText
        case readCards
        case readChoiceKind
        case target
        case resolveTarget
        case amountChoices
        case paymentChoices
        case usedInvestigators
        case pointsRemaining
        case chosenSupplies
        case resupply
        case drawings
        case key
        case value
        case source
        case fromInvestigator
        case fromInitialAmount
        case toInvestigator
        case toInitialAmount
        case token
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported question presentation protocol \(protocolVersion)"
            )
        }
        let questionVersion = try container.decode(Int.self, forKey: .questionVersion)
        guard questionVersion >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .questionVersion,
                in: container,
                debugDescription: "questionVersion must be non-negative"
            )
        }
        let questionKind = try container.decode(Kind.self, forKey: .questionKind)
        let choiceCount = try container.decode(Int.self, forKey: .choiceCount)
        guard choiceCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .choiceCount,
                in: container,
                debugDescription: "choiceCount must be non-negative"
            )
        }
        let choices = try container.decode([Choice].self, forKey: .choices)
        try Self.validateSourceIndices(choices, choiceCount: choiceCount, in: container)
        let presentation = try Self(
            protocolVersion: protocolVersion,
            questionVersion: questionVersion,
            questionKind: questionKind,
            choiceCount: choiceCount,
            choices: choices,
            answer: container.decode(Answer.self, forKey: .answer),
            selection: container.decodePresentIfContained(Selection.self, forKey: .selection),
            groups: container.decodePresentIfContained([Int].self, forKey: .groups),
            label: container.decodePresentIfContained(Label.self, forKey: .label),
            questionLabel: container.decodePresentIfContained(Label.self, forKey: .questionLabel),
            completionLabel: container.decodePresentIfContained(Label.self, forKey: .completionLabel),
            confirmLabel: container.decodePresentIfContained(Label.self, forKey: .confirmLabel),
            backLabel: container.decodePresentIfContained(Label.self, forKey: .backLabel),
            cardCode: container.decodePresentIfContained(String.self, forKey: .cardCode),
            payCost: container.decodePresentIfContained(Cost.self, forKey: .payCost),
            questionSource: container.decodePresentIfContained(Source.self, forKey: .questionSource),
            tooltip: container.decodePresentIfContained(String.self, forKey: .tooltip),
            flavorText: container.decodePresentIfContained(FlavorText.self, forKey: .flavorText),
            readCards: container.decodePresentIfContained([String].self, forKey: .readCards),
            readChoiceKind: container.decodePresentIfContained(ReadChoiceKind.self, forKey: .readChoiceKind),
            target: container.decodeNullableIfContained(AmountTarget.self, forKey: .target),
            resolveTarget: container.decodeTaggedJSONIfContained(forKey: .resolveTarget),
            amountChoices: container.decodePresentIfContained([AmountChoice].self, forKey: .amountChoices),
            paymentChoices: container.decodePresentIfContained([PaymentAmountChoice].self, forKey: .paymentChoices),
            usedInvestigators: container.decodePresentIfContained([String].self, forKey: .usedInvestigators),
            pointsRemaining: container.decodePresentIfContained(Int.self, forKey: .pointsRemaining),
            chosenSupplies: container.decodePresentIfContained([String].self, forKey: .chosenSupplies),
            resupply: container.decodePresentIfContained(Bool.self, forKey: .resupply),
            drawings: container.decodePresentIfContained([DestinyDrawing].self, forKey: .drawings),
            key: container.decodePresentIfContained(String.self, forKey: .key),
            value: container.decodePresentIfContained(JSONValue.self, forKey: .value),
            source: container.decodePresentIfContained(Source.self, forKey: .source),
            fromInvestigator: container.decodePresentIfContained(String.self, forKey: .fromInvestigator),
            fromInitialAmount: container.decodePresentIfContained(Int.self, forKey: .fromInitialAmount),
            toInvestigator: container.decodePresentIfContained(String.self, forKey: .toInvestigator),
            toInitialAmount: container.decodePresentIfContained(Int.self, forKey: .toInitialAmount),
            token: container.decodePresentIfContained(String.self, forKey: .token)
        )
        try presentation.validateDecodedShape(in: container)
        self = presentation
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid question presentation")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(questionVersion, forKey: .questionVersion)
        try container.encode(questionKind, forKey: .questionKind)
        try container.encode(choiceCount, forKey: .choiceCount)
        try container.encode(choices, forKey: .choices)
        try container.encode(answer, forKey: .answer)
        try container.encodeIfPresent(selection, forKey: .selection)
        try container.encodeIfPresent(groups, forKey: .groups)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(questionLabel, forKey: .questionLabel)
        try container.encodeIfPresent(completionLabel, forKey: .completionLabel)
        try container.encodeIfPresent(confirmLabel, forKey: .confirmLabel)
        try container.encodeIfPresent(backLabel, forKey: .backLabel)
        try container.encodeIfPresent(cardCode, forKey: .cardCode)
        try container.encodeIfPresent(payCost, forKey: .payCost)
        try container.encodeIfPresent(questionSource, forKey: .questionSource)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(flavorText, forKey: .flavorText)
        try container.encodeIfPresent(readCards, forKey: .readCards)
        try container.encodeIfPresent(readChoiceKind, forKey: .readChoiceKind)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(resolveTarget, forKey: .resolveTarget)
        try container.encodeIfPresent(amountChoices, forKey: .amountChoices)
        try container.encodeIfPresent(paymentChoices, forKey: .paymentChoices)
        try container.encodeIfPresent(usedInvestigators, forKey: .usedInvestigators)
        try container.encodeIfPresent(pointsRemaining, forKey: .pointsRemaining)
        try container.encodeIfPresent(chosenSupplies, forKey: .chosenSupplies)
        try container.encodeIfPresent(resupply, forKey: .resupply)
        try container.encodeIfPresent(drawings, forKey: .drawings)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(fromInvestigator, forKey: .fromInvestigator)
        try container.encodeIfPresent(fromInitialAmount, forKey: .fromInitialAmount)
        try container.encodeIfPresent(toInvestigator, forKey: .toInvestigator)
        try container.encodeIfPresent(toInitialAmount, forKey: .toInitialAmount)
        try container.encodeIfPresent(token, forKey: .token)
    }

    private static func validateSourceIndices(
        _ choices: [Choice],
        choiceCount: Int,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let sourceIndices = choices.map(\.sourceIndex)
        guard sourceIndices.sorted() == Array(0 ..< choiceCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .choices,
                in: container,
                debugDescription: "Choice sourceIndex values must cover 0..<choiceCount exactly"
            )
        }
    }

    private func validateDecodedShape(in container: KeyedDecodingContainer<CodingKeys>) throws {
        guard isValidShape else {
            throw DecodingError.dataCorruptedError(
                forKey: .choices,
                in: container,
                debugDescription: "Invalid question presentation"
            )
        }
        switch questionKind {
        case .chooseN, .chooseSome, .chooseSome1, .chooseUpToN,
             .chooseOneAtATime, .chooseOneAtATimeWithAuto:
            try require(selection, .selection, in: container)
            try requireSingleChoiceAnswer(in: container)
        case .chooseOneFromEach:
            try require(selection, .selection, in: container)
            try require(groups, .groups, in: container)
            try requireSingleChoiceAnswer(in: container)
        case .chooseAmounts:
            try require(label, .label, in: container)
            try require(target, .target, in: container)
            try require(resolveTarget, .resolveTarget, in: container)
            try require(amountChoices, .amountChoices, in: container)
            guard case .amounts = answer else { try answerMismatch(in: container) }
        case .choosePaymentAmounts:
            try require(label, .label, in: container)
            try requireContained(.target, in: container)
            try require(paymentChoices, .paymentChoices, in: container)
            guard case .paymentAmounts = answer else { try answerMismatch(in: container) }
        case .chooseExchangeAmounts:
            try require(source, .source, in: container)
            try require(fromInvestigator, .fromInvestigator, in: container)
            try require(fromInitialAmount, .fromInitialAmount, in: container)
            try require(toInvestigator, .toInvestigator, in: container)
            try require(toInitialAmount, .toInitialAmount, in: container)
            try require(token, .token, in: container)
            guard case .exchangeAmounts = answer else { try answerMismatch(in: container) }
        case .chooseDeck, .chooseUpgradeDeck, .chooseJoinDeck:
            guard case .deck = answer else { try answerMismatch(in: container) }
            if questionKind == .chooseJoinDeck {
                try require(usedInvestigators, .usedInvestigators, in: container)
            }
        case .read:
            try require(flavorText, .flavorText, in: container)
            try require(readChoiceKind, .readChoiceKind, in: container)
            try requireSingleChoiceAnswer(in: container)
        case .chooseOneWizard:
            try require(flavorText, .flavorText, in: container)
            try require(confirmLabel, .confirmLabel, in: container)
            try require(backLabel, .backLabel, in: container)
            try requireSingleChoiceAnswer(in: container)
        case .pickSupplies:
            try require(pointsRemaining, .pointsRemaining, in: container)
            try require(chosenSupplies, .chosenSupplies, in: container)
            try require(resupply, .resupply, in: container)
            try requireSingleChoiceAnswer(in: container)
        case .pickDestiny:
            try require(drawings, .drawings, in: container)
            guard case .pickDestiny = answer else { try answerMismatch(in: container) }
        case .pickCampaignSpecific:
            try require(key, .key, in: container)
            try requireContained(.value, in: container)
            guard case .campaignSpecific = answer else { try answerMismatch(in: container) }
        case .pickScenarioSpecific:
            try require(key, .key, in: container)
            try requireContained(.value, in: container)
            guard case .scenarioSpecific = answer else { try answerMismatch(in: container) }
        case .continueCampaign:
            guard case .continueCampaign = answer else { try answerMismatch(in: container) }
        case .pickCampaignSettings:
            guard case .campaignSettings = answer else { try answerMismatch(in: container) }
        case .pickScenarioSettings:
            guard case .standaloneSettings = answer else { try answerMismatch(in: container) }
        case .chooseOne, .dropDown, .playerWindowChooseOne, .windowChooseOne:
            try requireSingleChoiceAnswer(in: container)
        case .unsupported:
            break
        }
    }

    private var isValidShape: Bool {
        guard protocolVersion == Self.supportedProtocolVersion,
              questionVersion >= 0,
              choiceCount >= 0,
              questionKind != .unsupported,
              choices.allSatisfy(\.isValidShape),
              selection?.isValidShape != false,
              groups?.allSatisfy({ $0 >= 0 }) != false,
              choices.map(\.sourceIndex).sorted() == Array(0 ..< choiceCount)
        else { return false }
        return true
    }

    private func require(
        _ value: (some Any)?, _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard value != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Missing required \(key.stringValue)"
            )
        }
    }

    private func requireContained(
        _ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard container.contains(key) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Missing required \(key.stringValue)"
            )
        }
    }

    private func requireSingleChoiceAnswer(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard case .singleChoice = answer else { try answerMismatch(in: container) }
    }

    private func answerMismatch(in container: KeyedDecodingContainer<CodingKeys>) throws -> Never {
        throw DecodingError.dataCorruptedError(
            forKey: .answer,
            in: container,
            debugDescription: "answer kind does not match questionKind"
        )
    }
}

private extension QuestionPresentation.Selection {
    var isValidShape: Bool {
        min >= 0 && max >= 0 && min <= max
    }
}

extension QuestionPresentation.Choice: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceIndex
        case kind
        case selectable
        case completesSelection
        case actorID = "actorId"
        case entity
        case label
        case ability
        case cost
        case flippable
        case face
        case key
        case skillType
        case connection
        case tarotCard
        case component
        case source
        case step
        case tooltip
        case cards
        case flavorText
        case uiTag
        case target
        case groupIndex
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        let choice = try Self(
            sourceIndex: container.decode(Int.self, forKey: .sourceIndex),
            kind: container.decode(QuestionPresentation.ChoiceKind.self, forKey: .kind),
            selectable: container.decode(Bool.self, forKey: .selectable),
            completesSelection: container.decodePresentIfContained(Bool.self, forKey: .completesSelection),
            actorID: container.decodePresentIfContained(String.self, forKey: .actorID),
            entity: container.decodePresentIfContained(QuestionPresentation.Entity.self, forKey: .entity),
            label: container.decodePresentIfContained(QuestionPresentation.Label.self, forKey: .label),
            ability: container.decodePresentIfContained(QuestionPresentation.Ability.self, forKey: .ability),
            cost: container.decodePresentIfContained(QuestionPresentation.Cost.self, forKey: .cost),
            flippable: container.decodePresentIfContained(Bool.self, forKey: .flippable),
            face: container.decodePresentIfContained(String.self, forKey: .face),
            key: container.decodeTaggedJSONIfContained(forKey: .key),
            skillType: container.decodePresentIfContained(QuestionPresentation.SkillType.self, forKey: .skillType),
            connection: container.decodePresentIfContained(QuestionPresentation.LocationSymbol.self, forKey: .connection),
            tarotCard: container.decodePresentIfContained(QuestionPresentation.TarotCard.self, forKey: .tarotCard),
            component: container.decodePresentIfContained(QuestionPresentation.Component.self, forKey: .component),
            source: container.decodePresentIfContained(QuestionPresentation.Source.self, forKey: .source),
            step: container.decodeChaosBagStepIfContained(forKey: .step),
            tooltip: container.decodePresentIfContained(String.self, forKey: .tooltip),
            cards: container.decodePresentIfContained([QuestionPresentation.PileCard].self, forKey: .cards),
            flavorText: container.decodePresentIfContained(QuestionPresentation.FlavorText.self, forKey: .flavorText),
            uiTag: container.decodePresentIfContained(String.self, forKey: .uiTag),
            target: container.decodeTaggedJSONIfContained(forKey: .target),
            groupIndex: container.decodePresentIfContained(Int.self, forKey: .groupIndex)
        )
        try choice.validateDecodedShape(in: container)
        self = choice
    }

    func encode(to encoder: any Encoder) throws {
        guard isValidShape else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid semantic choice descriptor")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceIndex, forKey: .sourceIndex)
        try container.encode(kind, forKey: .kind)
        try container.encode(selectable, forKey: .selectable)
        try container.encodeIfPresent(completesSelection, forKey: .completesSelection)
        try container.encodeIfPresent(actorID, forKey: .actorID)
        try container.encodeIfPresent(entity, forKey: .entity)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(ability, forKey: .ability)
        try container.encodeIfPresent(cost, forKey: .cost)
        try container.encodeIfPresent(flippable, forKey: .flippable)
        try container.encodeIfPresent(face, forKey: .face)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(skillType, forKey: .skillType)
        try container.encodeIfPresent(connection, forKey: .connection)
        try container.encodeIfPresent(tarotCard, forKey: .tarotCard)
        try container.encodeIfPresent(component, forKey: .component)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(step, forKey: .step)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(cards, forKey: .cards)
        try container.encodeIfPresent(flavorText, forKey: .flavorText)
        try container.encodeIfPresent(uiTag, forKey: .uiTag)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(groupIndex, forKey: .groupIndex)
    }

    fileprivate var isValidShape: Bool {
        sourceIndex >= 0
            && (groupIndex == nil || groupIndex ?? -1 >= 0)
            && ability?.isValidShape != false
            && cost?.isValidShape != false
            && isKindValid
    }

    private var isKindValid: Bool {
        switch kind {
        case .advanceAct:
            entity?.kind == .act
        case .advanceAgenda:
            entity?.kind == .agenda
        case .assignDamage, .assignHorror:
            actorID == nil && entity?.kind == .investigator && ability == nil && cost == nil
        case .chooseTarget:
            entity != nil
        case .move:
            entity?.kind == .location && ability != nil && cost != nil
        case .resolveForcedAbility:
            (entity?.kind == .location || entity?.kind == .treachery) && ability != nil && cost != nil
        case .useAbility:
            ability != nil && cost != nil
        case .drawCard, .drawEncounterCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest:
            actorID != nil
        case .localizedLabel, .auto, .wizardChoice:
            label != nil
        case .invalidLabel:
            label != nil && !selectable
        case .costLabel:
            cost != nil
        case .skillLabel:
            skillType != nil
        case .info:
            flavorText != nil && !selectable
        case .opaque:
            uiTag != nil
        case .connectionLabel:
            connection != nil
        case .chaosTokenLabel:
            face != nil
        case .keyLabel:
            key != nil
        case .tarotLabel:
            tarotCard != nil
        case .componentLabel, .auxiliaryComponentLabel:
            component != nil
        case .chaosTokenGroupChoice:
            actorID != nil && source != nil && step != nil
        case .effectActionButton:
            entity?.kind == .effect && tooltip != nil
        case .cardPile:
            cards != nil
        case .applySkillTestResults, .engage, .evade, .fight, .investigate:
            true
        }
    }

    private func validateDecodedShape(in container: KeyedDecodingContainer<CodingKeys>) throws {
        guard isValidShape else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid semantic choice descriptor"
            )
        }
    }
}

extension QuestionPresentation.Answer: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case tag
        case tags
        case alternateTags
    }

    private enum Kind: String, Codable {
        case singleChoice
        case amounts
        case paymentAmounts
        case exchangeAmounts
        case deck
        case standaloneSettings
        case campaignSettings
        case pickDestiny
        case campaignSpecific
        case scenarioSpecific
        case continueCampaign
    }

    init(from decoder: any Decoder) throws {
        let kindContainer = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try kindContainer.decode(Kind.self, forKey: .kind)
        let allowed: [CodingKeys] = switch kind {
        case .deck, .continueCampaign: [.kind, .tags]
        case .singleChoice: [.kind, .tag, .alternateTags]
        default: [.kind, .tag]
        }
        let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: allowed)
        switch kind {
        case .singleChoice:
            try Self.requireTag("Answer", in: container)
            let alternateTags = try container.decodePresentIfContained([String].self, forKey: .alternateTags)
            if let alternateTags, alternateTags != ["OrderedAnswer"] {
                throw DecodingError.dataCorruptedError(forKey: .alternateTags, in: container, debugDescription: "Unsupported alternate answer tags")
            }
            self = .singleChoice(alternateTags: alternateTags)
        case .amounts:
            try Self.requireTag("AmountsAnswer", in: container)
            self = .amounts
        case .paymentAmounts:
            try Self.requireTag("PaymentAmountsAnswer", in: container)
            self = .paymentAmounts
        case .exchangeAmounts:
            try Self.requireTag("ExchangeAmountsAnswer", in: container)
            self = .exchangeAmounts
        case .deck:
            let tags = try container.decode([String].self, forKey: .tags)
            guard tags == ["DeckAnswer", "DeckListAnswer"] else {
                throw DecodingError.dataCorruptedError(forKey: .tags, in: container, debugDescription: "Unsupported deck answer tags")
            }
            self = .deck(tags: tags)
        case .standaloneSettings:
            try Self.requireTag("StandaloneSettingsAnswer", in: container)
            self = .standaloneSettings
        case .campaignSettings:
            try Self.requireTag("CampaignSettingsAnswer", in: container)
            self = .campaignSettings
        case .pickDestiny:
            try Self.requireTag("PickDestinyAnswer", in: container)
            self = .pickDestiny
        case .campaignSpecific:
            try Self.requireTag("CampaignSpecificAnswer", in: container)
            self = .campaignSpecific
        case .scenarioSpecific:
            try Self.requireTag("ScenarioSpecificAnswer", in: container)
            self = .scenarioSpecific
        case .continueCampaign:
            let tags = try container.decode([String].self, forKey: .tags)
            let allowedTags: Set = [
                "CampaignStepAnswer",
                "RetireInvestigatorAnswer",
                "RejoinInvestigatorAnswer",
                "ApplyOverlayAnswer",
                "JoinCampaignAnswer",
            ]
            guard !tags.isEmpty,
                  Set(tags).count == tags.count,
                  Set(tags).isSubset(of: allowedTags)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tags,
                    in: container,
                    debugDescription: "Invalid continue-campaign tags"
                )
            }
            self = .continueCampaign(tags: tags)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .singleChoice(alternateTags):
            try container.encode(Kind.singleChoice, forKey: .kind)
            try container.encode("Answer", forKey: .tag)
            try container.encodeIfPresent(alternateTags, forKey: .alternateTags)
        case .amounts:
            try encode(.amounts, tag: "AmountsAnswer", to: &container)
        case .paymentAmounts:
            try encode(.paymentAmounts, tag: "PaymentAmountsAnswer", to: &container)
        case .exchangeAmounts:
            try encode(.exchangeAmounts, tag: "ExchangeAmountsAnswer", to: &container)
        case let .deck(tags):
            try container.encode(Kind.deck, forKey: .kind)
            try container.encode(tags, forKey: .tags)
        case .standaloneSettings:
            try encode(.standaloneSettings, tag: "StandaloneSettingsAnswer", to: &container)
        case .campaignSettings:
            try encode(.campaignSettings, tag: "CampaignSettingsAnswer", to: &container)
        case .pickDestiny:
            try encode(.pickDestiny, tag: "PickDestinyAnswer", to: &container)
        case .campaignSpecific:
            try encode(.campaignSpecific, tag: "CampaignSpecificAnswer", to: &container)
        case .scenarioSpecific:
            try encode(.scenarioSpecific, tag: "ScenarioSpecificAnswer", to: &container)
        case let .continueCampaign(tags):
            try container.encode(Kind.continueCampaign, forKey: .kind)
            try container.encode(tags, forKey: .tags)
        }
    }

    private static func requireTag(
        _ expected: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let actual = try container.decode(String.self, forKey: .tag)
        guard actual == expected else {
            throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: "Expected \(expected)")
        }
    }

    private func encode(
        _ kind: Kind,
        tag: String,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(tag, forKey: .tag)
    }
}

extension QuestionPresentation.Entity: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, id }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: Array(CodingKeys.allCases))
        try self.init(kind: container.decode(QuestionPresentation.EntityKind.self, forKey: .kind), id: container.decode(String.self, forKey: .id))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
    }
}

extension QuestionPresentation.Label: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, text }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: Array(CodingKeys.allCases))
        try self.init(kind: container.decode(QuestionPresentation.LabelKind.self, forKey: .kind), text: container.decode(String.self, forKey: .text))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
    }
}

extension QuestionPresentation.Source: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case raw, entity }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: Array(CodingKeys.allCases))
        let raw = try container.decode(JSONValue.self, forKey: .raw)
        try Self.validateRawSource(raw, codingPath: decoder.codingPath + [CodingKeys.raw])
        try self.init(raw: raw, entity: container.decodePresentIfContained(QuestionPresentation.Entity.self, forKey: .entity))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        try container.encodeIfPresent(entity, forKey: .entity)
    }

    fileprivate static func validateRawSource(_ value: JSONValue, codingPath: [any CodingKey]) throws {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"],
              !tag.isEmpty
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Source raw must be a tagged object"))
        }
        if tag == "ProxySource" {
            guard Set(object.keys) == ["tag", "source", "originalSource"],
                  let source = object["source"],
                  let originalSource = object["originalSource"]
            else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Malformed ProxySource"))
            }
            try validateRawSource(source, codingPath: codingPath)
            try validateRawSource(originalSource, codingPath: codingPath)
        } else {
            guard Set(object.keys).isSubset(of: ["tag", "contents"]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Malformed tagged source"))
            }
        }
    }
}

extension QuestionPresentation.Component: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tag
        case investigatorID = "investigatorId"
        case assetID = "assetId"
        case tokenType
    }

    init(from decoder: any Decoder) throws {
        let tagContainer = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try tagContainer.decode(String.self, forKey: .tag)
        switch tag {
        case "InvestigatorComponent":
            let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: [.tag, .investigatorID, .tokenType])
            self = try .investigator(
                investigatorID: container.decode(String.self, forKey: .investigatorID),
                tokenType: container.decode(QuestionPresentation.GameTokenType.self, forKey: .tokenType)
            )
        case "InvestigatorDeckComponent":
            let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: [.tag, .investigatorID])
            self = try .investigatorDeck(investigatorID: container.decode(String.self, forKey: .investigatorID))
        case "AssetComponent":
            let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: [.tag, .assetID, .tokenType])
            self = try .asset(
                assetID: container.decode(String.self, forKey: .assetID),
                tokenType: container.decode(QuestionPresentation.GameTokenType.self, forKey: .tokenType)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .tag, in: tagContainer, debugDescription: "Unknown component tag")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .investigator(investigatorID, tokenType):
            try container.encode("InvestigatorComponent", forKey: .tag)
            try container.encode(investigatorID, forKey: .investigatorID)
            try container.encode(tokenType, forKey: .tokenType)
        case let .investigatorDeck(investigatorID):
            try container.encode("InvestigatorDeckComponent", forKey: .tag)
            try container.encode(investigatorID, forKey: .investigatorID)
        case let .asset(assetID, tokenType):
            try container.encode("AssetComponent", forKey: .tag)
            try container.encode(assetID, forKey: .assetID)
            try container.encode(tokenType, forKey: .tokenType)
        }
    }
}

extension QuestionPresentation.AmountTarget: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case tag, contents }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(decoder, keyedBy: CodingKeys.self, allowing: Array(CodingKeys.allCases))
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "MinAmountTarget": self = try .min(container.decode(Int.self, forKey: .contents))
        case "MaxAmountTarget": self = try .max(container.decode(Int.self, forKey: .contents))
        case "TotalAmountTarget": self = try .total(container.decode(Int.self, forKey: .contents))
        case "AmountOneOf": self = try .oneOf(container.decode([Int].self, forKey: .contents))
        default:
            throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: "Unknown amount target")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .min(value):
            try container.encode("MinAmountTarget", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .max(value):
            try container.encode("MaxAmountTarget", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .total(value):
            try container.encode("TotalAmountTarget", forKey: .tag)
            try container.encode(value, forKey: .contents)
        case let .oneOf(values):
            try container.encode("AmountOneOf", forKey: .tag)
            try container.encode(values, forKey: .contents)
        }
    }
}

extension QuestionPresentation.Selection {
    private enum CodingKeys: String, CodingKey, CaseIterable { case min, max }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            min: container.decode(Int.self, forKey: .min),
            max: container.decode(Int.self, forKey: .max)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(min, forKey: .min)
        try container.encode(max, forKey: .max)
    }
}

extension QuestionPresentation.TarotCard {
    private enum CodingKeys: String, CodingKey, CaseIterable { case facing, arcana }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            facing: container.decode(Facing.self, forKey: .facing),
            arcana: container.decode(String.self, forKey: .arcana)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facing, forKey: .facing)
        try container.encode(arcana, forKey: .arcana)
    }
}

extension QuestionPresentation.FlavorText {
    private enum CodingKeys: String, CodingKey, CaseIterable { case title, body }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        guard container.contains(.title) else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing required nullable title"
                )
            )
        }
        let title: String? = if try container.decodeNil(forKey: .title) {
            nil
        } else {
            try container.decode(String.self, forKey: .title)
        }
        try self.init(
            title: title,
            body: container.decode([JSONValue].self, forKey: .body)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        if title == nil {
            try container.encodeNil(forKey: .title)
        }
        try container.encode(body, forKey: .body)
    }
}

extension QuestionPresentation.PileCard {
    private enum CodingKeys: String, CodingKey, CaseIterable { case cardID = "cardId", cardOwner }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        guard container.contains(.cardOwner) else {
            throw DecodingError.keyNotFound(
                CodingKeys.cardOwner,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing required nullable cardOwner"
                )
            )
        }
        let owner: String? = if try container.decodeNil(forKey: .cardOwner) {
            nil
        } else {
            try container.decode(String.self, forKey: .cardOwner)
        }
        try self.init(
            cardID: container.decode(String.self, forKey: .cardID),
            cardOwner: owner
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardID, forKey: .cardID)
        try container.encodeIfPresent(cardOwner, forKey: .cardOwner)
        if cardOwner == nil {
            try container.encodeNil(forKey: .cardOwner)
        }
    }
}

extension QuestionPresentation.AmountChoice {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case choiceID = "choiceId", label, minBound, maxBound
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            choiceID: container.decode(String.self, forKey: .choiceID),
            label: container.decode(String.self, forKey: .label),
            minBound: container.decode(Int.self, forKey: .minBound),
            maxBound: container.decode(Int.self, forKey: .maxBound)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(choiceID, forKey: .choiceID)
        try container.encode(label, forKey: .label)
        try container.encode(minBound, forKey: .minBound)
        try container.encode(maxBound, forKey: .maxBound)
    }
}

extension QuestionPresentation.PaymentAmountChoice {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case choiceID = "choiceId", investigatorID = "investigatorId", min, max, title
    }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            choiceID: container.decode(String.self, forKey: .choiceID),
            investigatorID: container.decode(String.self, forKey: .investigatorID),
            min: container.decode(Int.self, forKey: .min),
            max: container.decode(Int.self, forKey: .max),
            title: container.decode(QuestionPresentation.Label.self, forKey: .title)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(choiceID, forKey: .choiceID)
        try container.encode(investigatorID, forKey: .investigatorID)
        try container.encode(min, forKey: .min)
        try container.encode(max, forKey: .max)
        try container.encode(title, forKey: .title)
    }
}

extension QuestionPresentation.DestinyDrawing {
    private enum CodingKeys: String, CodingKey, CaseIterable { case scenario, tarot }

    init(from decoder: any Decoder) throws {
        let container = try questionPresentationClosedContainer(
            decoder,
            keyedBy: CodingKeys.self,
            allowing: Array(CodingKeys.allCases)
        )
        try self.init(
            scenario: container.decode(JSONValue.self, forKey: .scenario),
            tarot: container.decode(QuestionPresentation.TarotCard.self, forKey: .tarot)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(tarot, forKey: .tarot)
    }
}

func questionPresentationClosedContainer<Key: CodingKey>(
    _ decoder: any Decoder,
    keyedBy type: Key.Type,
    allowing allowedKeys: [Key]
) throws -> KeyedDecodingContainer<Key> {
    let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(allowedKeys.map(\.stringValue))
    let unknown = Set(rawContainer.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected keys: \(unknown.sorted().joined(separator: ", "))"
            )
        )
    }
    return try decoder.container(keyedBy: type)
}

extension KeyedDecodingContainer {
    func decodePresentIfContained<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeNullableIfContained<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeTaggedJSONIfContained(forKey key: Key) throws -> JSONValue? {
        guard contains(key) else { return nil }
        let value = try decode(JSONValue.self, forKey: key)
        try QuestionPresentationJSONShape.validateTaggedJSON(
            value,
            codingPath: codingPath + [key]
        )
        return value
    }

    func decodeChaosBagStepIfContained(forKey key: Key) throws -> JSONValue? {
        guard contains(key) else { return nil }
        let value = try decode(JSONValue.self, forKey: key)
        try QuestionPresentationJSONShape.validateChaosBagStep(
            value,
            codingPath: codingPath + [key]
        )
        return value
    }
}

enum QuestionPresentationJSONShape {
    static func validateTaggedJSON(_ value: JSONValue, codingPath: [any CodingKey]) throws {
        guard case let .object(object) = value,
              case .string? = object["tag"],
              Set(object.keys).isSubset(of: ["tag", "contents"])
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Expected tagged JSON object"
            ))
        }
    }

    static func validateChaosBagStep(_ value: JSONValue, codingPath: [any CodingKey]) throws {
        guard case let .object(object) = value,
              case .string? = object["tag"]
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Expected chaos bag step object"
            ))
        }
        let taggedKeys: Set = ["tag", "contents"]
        if Set(object.keys).isSubset(of: taggedKeys) {
            return
        }
        let allowed: Set = [
            "tag", "source", "amount", "tokenStrategy", "steps", "tokenGroups",
            "chooseAndThen", "tokenMatcher", "tokenMatcherChoices",
        ]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Unexpected chaos bag step keys"
            ))
        }
        if let source = object["source"] {
            try QuestionPresentation.Source.validateRawSource(
                source,
                codingPath: codingPath + [AnyCodingKey(stringValue: "source")]
            )
        }
        if let amount = object["amount"], !isInteger(amount) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath + [AnyCodingKey(stringValue: "amount")],
                debugDescription: "amount must be an integer"
            ))
        }
        try requireArrayIfPresent(
            object["steps"],
            key: "steps",
            codingPath: codingPath
        )
        try requireArrayIfPresent(
            object["tokenGroups"],
            key: "tokenGroups",
            codingPath: codingPath
        )
        try requireArrayIfPresent(
            object["tokenMatcherChoices"],
            key: "tokenMatcherChoices",
            codingPath: codingPath
        )
        if let chooseAndThen = object["chooseAndThen"], chooseAndThen != .null {
            try validateChaosBagStep(
                chooseAndThen,
                codingPath: codingPath + [AnyCodingKey(stringValue: "chooseAndThen")]
            )
        }
    }

    private static func requireArrayIfPresent(
        _ value: JSONValue?,
        key: String,
        codingPath: [any CodingKey]
    ) throws {
        guard let value else { return }
        guard case .array = value else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath + [AnyCodingKey(stringValue: key)],
                debugDescription: "\(key) must be an array"
            ))
        }
    }

    private static func isInteger(_ value: JSONValue) -> Bool {
        guard case let .number(number) = value else { return false }
        return number.exponent.isZero
    }
}

// swiftlint:enable file_length function_body_length cyclomatic_complexity line_length
