extension BasicChoicePromptPresentation {
    private enum SemanticCostComposition {
        case all
        case choice
    }

    private enum SemanticCostUnit {
        case action
        case resource
        case clue
    }

    func semanticCostSummary(
        _ cost: QuestionPresentation.Cost,
        in projection: BoardProjection
    ) -> String {
        semanticCostSummary(cost, in: projection, enclosingComposition: nil)
    }

    private func semanticCostSummary(
        _ cost: QuestionPresentation.Cost,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition?
    ) -> String {
        switch cost {
        case .free:
            return semanticLocalized(
                "semantic.cost.free",
                value: "free"
            )
        case let .action(amount):
            return semanticCount(amount, unit: .action)
        case let .resource(amount):
            return semanticCount(amount, unit: .resource)
        case let .clue(amount):
            return semanticAmountSummary(amount, unit: .clue)
        case let .groupClue(amount, scope):
            let amountSummary = semanticAmountSummary(amount, unit: .clue)
            let scopeSummary = semanticScopeSummary(scope, in: projection)
            return semanticLocalized(
                "semantic.cost.join.scope",
                value: "\(amountSummary) \(scopeSummary)",
                arguments: [amountSummary, scopeSummary]
            )
        case let .groupResource(amount, scope):
            let amountSummary = semanticAmountSummary(amount, unit: .resource)
            let scopeSummary = semanticScopeSummary(scope, in: projection)
            return semanticLocalized(
                "semantic.cost.join.scope",
                value: "\(amountSummary) \(scopeSummary)",
                arguments: [amountSummary, scopeSummary]
            )
        case let .all(costs):
            return semanticCompositeCostSummary(
                costs,
                composition: .all,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case let .choice(costs):
            return semanticCompositeCostSummary(
                costs,
                composition: .choice,
                in: projection,
                enclosingComposition: enclosingComposition
            )
        case .other:
            return semanticLocalized(
                "semantic.cost.additional",
                value: "additional cost"
            )
        }
    }

    private func semanticCompositeCostSummary(
        _ costs: [QuestionPresentation.Cost],
        composition: SemanticCostComposition,
        in projection: BoardProjection,
        enclosingComposition: SemanticCostComposition?
    ) -> String {
        let summaries = costs.map {
            semanticCostSummary(
                $0,
                in: projection,
                enclosingComposition: composition
            )
        }
        guard let first = summaries.first else { return "" }
        let summary = summaries.dropFirst().reduce(first) { partial, next in
            switch composition {
            case .all:
                semanticLocalized(
                    "semantic.cost.join.all",
                    value: "\(partial) and \(next)",
                    arguments: [partial, next]
                )
            case .choice:
                semanticLocalized(
                    "semantic.cost.join.choice",
                    value: "\(partial) or \(next)",
                    arguments: [partial, next]
                )
            }
        }
        guard let enclosingComposition, enclosingComposition != composition else {
            return summary
        }
        return "(\(summary))"
    }

    private func semanticAmountSummary(
        _ amount: QuestionPresentation.Amount,
        unit: SemanticCostUnit
    ) -> String {
        switch amount {
        case let .fixed(value):
            return semanticCount(value, unit: unit)
        case let .perPlayer(value):
            let count = semanticCount(value, unit: unit)
            return semanticLocalized(
                "semantic.cost.amount.perInvestigator",
                value: "\(count) per investigator",
                arguments: [count]
            )
        case let .fixedPlusPerPlayer(fixed, perPlayer):
            let fixedSummary = semanticCount(fixed, unit: unit)
            let perPlayerSummary = semanticCount(perPlayer, unit: unit)
            return semanticLocalized(
                "semantic.cost.amount.fixedPlusPerInvestigator",
                value: "\(fixedSummary) + \(perPlayerSummary) per investigator",
                arguments: [fixedSummary, perPlayerSummary]
            )
        case let .byPlayerCount(values):
            let counts = values.map(String.init).joined(separator: "/")
            let pluralUnit = semanticUnit(unit, plural: true)
            return semanticLocalized(
                "semantic.cost.amount.byPlayerCount",
                value: "\(counts) \(pluralUnit) by player count",
                arguments: [counts, pluralUnit]
            )
        case .variable:
            let pluralUnit = semanticUnit(unit, plural: true)
            return semanticLocalized(
                "semantic.cost.amount.variable",
                value: "X \(pluralUnit)",
                arguments: [pluralUnit]
            )
        case .star:
            let pluralUnit = semanticUnit(unit, plural: true)
            return semanticLocalized(
                "semantic.cost.amount.star",
                value: "★ \(pluralUnit)",
                arguments: [pluralUnit]
            )
        case .unknown:
            let pluralUnit = semanticUnit(unit, plural: true)
            return semanticLocalized(
                "semantic.cost.amount.unknown",
                value: "an unknown number of \(pluralUnit)",
                arguments: [pluralUnit]
            )
        }
    }

    private func semanticScopeSummary(
        _ scope: QuestionPresentation.Scope,
        in projection: BoardProjection
    ) -> String {
        switch scope {
        case .anywhere:
            return semanticLocalized(
                "semantic.cost.scope.anywhere",
                value: "from anywhere"
            )
        case .sameLocation:
            return semanticLocalized(
                "semantic.cost.scope.sameLocation",
                value: "at the same location"
            )
        case let .location(rawID):
            guard let id = LocationID(codingKey: AnyCodingKey(stringValue: rawID)) else {
                return semanticLocalized(
                    "semantic.cost.scope.specifiedLocation",
                    value: "at the specified location"
                )
            }
            if let location = projection.locations.first(where: { $0.id == id }) {
                return semanticLocalized(
                    "semantic.cost.scope.location",
                    value: "at \(location.displayLabel)",
                    arguments: [location.displayLabel]
                )
            }
            if let location = projection.enemyLocations.first(where: { $0.id == id }) {
                return semanticLocalized(
                    "semantic.cost.scope.location",
                    value: "at \(location.displayLabel)",
                    arguments: [location.displayLabel]
                )
            }
            return semanticLocalized(
                "semantic.cost.scope.specifiedLocation",
                value: "at the specified location"
            )
        case .other:
            return semanticLocalized(
                "semantic.cost.scope.requiredArea",
                value: "from the required area"
            )
        }
    }

    private func semanticCount(
        _ value: Int,
        unit: SemanticCostUnit
    ) -> String {
        let unitName = semanticUnit(unit, plural: value != 1)
        return semanticLocalized(
            "semantic.cost.count",
            value: "\(value) \(unitName)",
            arguments: [Int64(value), unitName]
        )
    }

    private func semanticUnit(_ unit: SemanticCostUnit, plural: Bool) -> String {
        switch (unit, plural) {
        case (.action, false):
            semanticLocalized(
                "semantic.cost.unit.action.singular",
                value: "action"
            )
        case (.action, true):
            semanticLocalized(
                "semantic.cost.unit.action.plural",
                value: "actions"
            )
        case (.resource, false):
            semanticLocalized(
                "semantic.cost.unit.resource.singular",
                value: "resource"
            )
        case (.resource, true):
            semanticLocalized(
                "semantic.cost.unit.resource.plural",
                value: "resources"
            )
        case (.clue, false):
            semanticLocalized(
                "semantic.cost.unit.clue.singular",
                value: "clue"
            )
        case (.clue, true):
            semanticLocalized(
                "semantic.cost.unit.clue.plural",
                value: "clues"
            )
        }
    }
}
