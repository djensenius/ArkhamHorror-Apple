import Foundation

// swiftlint:disable file_length

/// The stable ``SemanticFocusZone``s this board declares. Every zone name is a fixed
/// string literal, never derived from live entity data, so a snapshot replacement can
/// never accidentally rename a zone.
enum BoardFocusZone {
    static let scenario: SemanticFocusZone = "board.scenario"
    static let actAgenda: SemanticFocusZone = "board.actAgenda"
    static let locations: SemanticFocusZone = "board.locations"
    static let enemyLocations: SemanticFocusZone = "board.enemyLocations"
    static let investigators: SemanticFocusZone = "board.investigators"
    static let chaosBag: SemanticFocusZone = "board.chaosBag"
    static let prompt: SemanticFocusZone = "board.prompt"
    /// The inspector modal's own zone. Deliberately **not** a member of ``cycleOrder``:
    /// `cycleZone` must never land here, since this zone only ever exists to hold the
    /// inspector's single Close control while a modal is presented.
    static let inspector: SemanticFocusZone = "board.inspector"
    /// The linked-choice modal's own zone. Deliberately **not** a member of
    /// ``cycleOrder`` for the same modal-isolation reason as ``inspector``.
    static let linkedChoiceMenu: SemanticFocusZone = "board.linkedChoiceMenu"

    /// The fixed cycling order every ``BoardCommandController/cycleZone(_:)`` call walks,
    /// deliberately declared once here rather than derived from `FocusGraph.order` (whose
    /// own order is insertion order across every zone interleaved, not a meaningful
    /// zone-level sequence).
    static let cycleOrder: [SemanticFocusZone] = [
        scenario, prompt, actAgenda, locations, enemyLocations, investigators, chaosBag,
    ]
}

/// Deterministic ``SemanticFocusID`` construction for every board entity kind. Every
/// identifier is derived from the entity's own stable snapshot identity (a UUID or card
/// code), never from array index or view-generated state, so focus survives reordering.
enum BoardFocusID {
    static let scenarioHeader: SemanticFocusID = "board.scenario.header"
    static let chaosBagSummary: SemanticFocusID = "board.chaosBag.summary"
    /// The inspector modal's own Close control. A single, permanent, board-instance-local
    /// node (declared fresh in every ``BoardFocusGraphBuilder/makeGraph(projection:layout:)``
    /// call, so it never collides across separate ``BoardView``/``BoardCommandController``
    /// instances) that `presentModal(entry:)` actually transitions ``FocusCoordinator/
    /// currentFocus`` to — never the same node that was already focused, so a snapshot
    /// replacement/removal/reorder can never make presenting the inspector a no-op change
    /// that a SwiftUI `.onChange` fails to observe.
    static let inspectorClose: SemanticFocusID = "board.inspector.close"
    static let promptRetry: SemanticFocusID = "board.prompt.retry"
    static let promptCatalogRetry: SemanticFocusID = "board.prompt.catalogRetry"

    static func promptChoice(_ index: Int) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.prompt.choice.\(index)")
    }

    static func promptAmountDecrease(_ index: Int) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.prompt.amount.\(index).decrease")
    }

    static func promptAmountIncrease(_ index: Int) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.prompt.amount.\(index).increase")
    }

    static let promptAmountSubmit: SemanticFocusID = "board.prompt.amount.submit"
    static let promptExchangeDecrease: SemanticFocusID = "board.prompt.exchange.decrease"
    static let promptExchangeIncrease: SemanticFocusID = "board.prompt.exchange.increase"
    static let promptExchangeSubmit: SemanticFocusID = "board.prompt.exchange.submit"

    static func promptPickDestinyRow(_ index: Int) -> SemanticFocusID {
        .init(rawValue: "board.prompt.pickDestiny.row.\(index)")
    }

    static let promptPickDestinySubmit: SemanticFocusID = "board.prompt.pickDestiny.submit"
    static let promptStandaloneSettingsSubmit: SemanticFocusID =
        "board.prompt.standaloneSettings.submit"
    static let promptScenarioSpecificSubmit: SemanticFocusID =
        "board.prompt.scenarioSpecific.submit"

    static func promptScenarioSpecificCard(_ index: Int) -> SemanticFocusID {
        .init(rawValue: "board.prompt.scenarioSpecific.card.\(index)")
    }

    static func promptScarletKeysTravelAction(
        _ action: ScarletKeysTravelPromptPresentation.Action
    ) -> SemanticFocusID {
        .init(rawValue: "board.prompt.scarletKeysTravel.\(action.id)")
    }

    static func act(_ id: ActID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.act.\(id.description)")
    }

    static func agenda(_ id: AgendaID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.agenda.\(id.description)")
    }

    static func location(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.location.\(id.description)")
    }

    static func enemyLocation(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.enemyLocation.\(id.description)")
    }

    static func investigator(_ id: InvestigatorID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.investigator.\(id.description)")
    }

    static func promptElement(_ id: BoardPromptElementID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.promptElement.\(id.rawFocusComponent)")
    }

    static func locationEnemyActions(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.location.\(id.description).enemyActions")
    }

    static func enemyLocationEnemyActions(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.enemyLocation.\(id.description).enemyActions")
    }

    static func linkedChoiceMenuChoice(_ index: Int) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.linkedChoiceMenu.choice.\(index)")
    }
}

// swiftlint:disable type_body_length
/// Builds a deterministic ``FocusGraph`` from a ``BoardProjection`` and its matching
/// ``BoardLayout``. Every edge is either declared from real topology (ordinary locations,
/// via ``BoardLayout/neighbors``) or a simple top-to-bottom/left-to-right chain within a
/// zone (every other zone); ``FocusWrapPolicy/wrapWithinZone`` guarantees every entity
/// stays reachable by directional movement even where an explicit edge is absent.
enum BoardFocusGraphBuilder {
    // swiftlint:disable:next function_body_length
    static func makeGraph(
        projection: BoardProjection,
        layout: BoardLayout,
        prompt: BasicChoicePromptPresentation? = nil,
        amountDraft: [String: Int] = [:],
        exchangeAmount: Int = 0,
        fullPlayerAreaPlayerID: PlayerID? = nil,
        isSolo: Bool = false,
        linkedChoiceMenuRequest: BoardLinkedChoiceMenuRequest? = nil
    ) -> FocusGraph {
        var nodes: [FocusNode] = []
        var zoneEntryPoints: [SemanticFocusZone: SemanticFocusID] = [:]
        let choiceLinks = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)

        nodes.append(FocusNode(id: BoardFocusID.scenarioHeader, zone: BoardFocusZone.scenario))
        zoneEntryPoints[BoardFocusZone.scenario] = BoardFocusID.scenarioHeader

        let promptChoices = promptFocusIDs(
            prompt,
            projection: projection,
            amountDraft: amountDraft,
            exchangeAmount: exchangeAmount
        )
        appendVerticalChain(
            promptChoices, zone: BoardFocusZone.prompt,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        // Ordered agendas-then-acts to match `BoardActAgendaColumnView`'s own rendering
        // order (agenda tiles above act tiles), so the zone's entry point and up/down
        // focus traversal always agree with what's actually on screen.
        let actAgendaChain = projection.agendas.map { BoardFocusID.agenda($0.id) }
            + projection.acts.map { BoardFocusID.act($0.id) }
        appendVerticalChain(
            actAgendaChain, zone: BoardFocusZone.actAgenda,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        appendLocations(
            projection.locations, enemiesByLocationID: projection.enemiesByLocationID,
            choiceLinks: choiceLinks, layout: layout, nodes: &nodes,
            zoneEntryPoints: &zoneEntryPoints
        )

        let enemyLocationChain = enemyLocationFocusIDs(
            projection.enemyLocations,
            enemiesByLocationID: projection.enemiesByLocationID,
            choiceLinks: choiceLinks
        )
        appendHorizontalChain(
            enemyLocationChain, zone: BoardFocusZone.enemyLocations,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        let investigatorChain = investigatorFocusIDs(
            projection: projection,
            choiceLinks: choiceLinks,
            fullPlayerAreaPlayerID: fullPlayerAreaPlayerID,
            isSolo: isSolo
        )
        appendHorizontalChain(
            investigatorChain, zone: BoardFocusZone.investigators,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        nodes.append(FocusNode(id: BoardFocusID.chaosBagSummary, zone: BoardFocusZone.chaosBag))
        zoneEntryPoints[BoardFocusZone.chaosBag] = BoardFocusID.chaosBagSummary

        appendInspectorCloseNode(nodes: &nodes, zoneEntryPoints: &zoneEntryPoints)
        appendLinkedChoiceMenuNodes(
            linkedChoiceMenuRequest, nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        return FocusGraph(
            nodes: nodes, zoneEntryPoints: zoneEntryPoints, wrapPolicy: .wrapWithinZone
        )
    }

    private static func appendInspectorCloseNode(
        nodes: inout [FocusNode],
        zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        // Always present (independent of any projection content) so `presentModal(entry:)`
        // always has a real, distinct node to transition `currentFocus` to — see
        // `BoardFocusID.inspectorClose`'s own documentation. Excluded from `cycleOrder`,
        // so normal zone cycling never lands here.
        nodes.append(FocusNode(id: BoardFocusID.inspectorClose, zone: BoardFocusZone.inspector))
        zoneEntryPoints[BoardFocusZone.inspector] = BoardFocusID.inspectorClose
    }

    private static func appendLinkedChoiceMenuNodes(
        _ request: BoardLinkedChoiceMenuRequest?,
        nodes: inout [FocusNode],
        zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard let request else { return }
        appendVerticalChain(
            request.choices.map { BoardFocusID.linkedChoiceMenuChoice($0.choiceIndex) },
            zone: BoardFocusZone.linkedChoiceMenu,
            nodes: &nodes,
            zoneEntryPoints: &zoneEntryPoints
        )
    }

    private static func promptFocusIDs(
        _ prompt: BasicChoicePromptPresentation?,
        projection: BoardProjection,
        amountDraft: [String: Int],
        exchangeAmount: Int
    ) -> [SemanticFocusID] {
        var promptChoices: [SemanticFocusID] = []
        if let prompt, prompt.canSubmit {
            promptChoices = submittablePromptFocusIDs(
                prompt,
                projection: projection,
                amountDraft: amountDraft,
                exchangeAmount: exchangeAmount
            )
        }
        if prompt?.canRetry == true {
            promptChoices = [BoardFocusID.promptRetry]
        }
        if prompt?.canRetryCatalog == true {
            promptChoices.append(BoardFocusID.promptCatalogRetry)
        }
        return promptChoices
    }

    private static func submittablePromptFocusIDs(
        _ prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        amountDraft: [String: Int],
        exchangeAmount: Int
    ) -> [SemanticFocusID] {
        if let amountPrompt = prompt.amountPrompt(in: projection) {
            return amountPromptFocusIDs(amountPrompt, amountDraft: amountDraft)
        }
        if let exchangePrompt = prompt.exchangePrompt(in: projection) {
            return exchangePromptFocusIDs(exchangePrompt, exchangeAmount: exchangeAmount)
        }
        if let pickDestinyPrompt = prompt.pickDestinyPrompt?.presentation {
            return pickDestinyPrompt.rows.indices.map(BoardFocusID.promptPickDestinyRow)
                + [BoardFocusID.promptPickDestinySubmit]
        }
        if prompt.isStandaloneSettingsPrompt(in: projection) {
            return [BoardFocusID.promptStandaloneSettingsSubmit]
        }
        if let spiritDeckPrompt = prompt.laidToRestSpiritDeckPrompt {
            return spiritDeckPrompt.displayEntries.map {
                BoardFocusID.promptScenarioSpecificCard($0.id)
            } + [BoardFocusID.promptScenarioSpecificSubmit]
        }
        if let travelPrompt = prompt.scarletKeysTravelPrompt {
            return travelPrompt.actions
                .filter(\.isActionable)
                .map(BoardFocusID.promptScarletKeysTravelAction)
        }
        return prompt.displayOrderedChoices()
            .filter { prompt.isChoiceActionable($0, in: projection) }
            .map { BoardFocusID.promptChoice($0.index) }
    }

    private static func amountPromptFocusIDs(
        _ amountPrompt: BasicChoiceAmountPrompt,
        amountDraft: [String: Int]
    ) -> [SemanticFocusID] {
        let normalized = amountPrompt.normalizedAmounts(amountDraft)
        var ids = amountPrompt.visibleRows.enumerated().flatMap { index, row in
            var rowChoices: [SemanticFocusID] = []
            if amountPrompt.canAdjust(normalized, rowID: row.id, delta: -1) {
                rowChoices.append(BoardFocusID.promptAmountDecrease(index))
            }
            if amountPrompt.canAdjust(normalized, rowID: row.id, delta: 1) {
                rowChoices.append(BoardFocusID.promptAmountIncrease(index))
            }
            return rowChoices
        }
        ids.append(BoardFocusID.promptAmountSubmit)
        return ids
    }

    private static func exchangePromptFocusIDs(
        _ exchangePrompt: BasicChoiceExchangePrompt,
        exchangeAmount: Int
    ) -> [SemanticFocusID] {
        var ids: [SemanticFocusID] = []
        if exchangePrompt.canAdjust(amount: exchangeAmount, delta: -1) {
            ids.append(BoardFocusID.promptExchangeDecrease)
        }
        if exchangePrompt.canAdjust(amount: exchangeAmount, delta: 1) {
            ids.append(BoardFocusID.promptExchangeIncrease)
        }
        ids.append(BoardFocusID.promptExchangeSubmit)
        return ids
    }

    /// The zones that currently have at least one navigable node, in
    /// ``BoardFocusZone/cycleOrder``, for ``BoardCommandController``'s zone cycling. An
    /// empty optional zone (for example no acts/agendas at all) is simply skipped rather
    /// than cycled into and left with nothing to focus.
    static func nonEmptyZonesInCycleOrder(
        projection: BoardProjection,
        prompt: BasicChoicePromptPresentation? = nil,
        amountDraft: [String: Int] = [:],
        exchangeAmount: Int = 0
    ) -> [SemanticFocusZone] {
        var populated: Set<SemanticFocusZone> = [BoardFocusZone.scenario, BoardFocusZone.chaosBag]
        let hasActionableChoice = prompt?.displayOrderedChoices().contains {
            prompt?.isChoiceActionable($0, in: projection) == true
        } == true
        let hasAmountControls = prompt.map {
            !promptFocusIDs(
                $0,
                projection: projection,
                amountDraft: amountDraft,
                exchangeAmount: exchangeAmount
            ).isEmpty
        } == true
        let hasPromptFocus = prompt?.canRetryCatalog == true
            || prompt?.canRetry == true
            || (prompt?.canSubmit == true && (hasActionableChoice || hasAmountControls))
        if hasPromptFocus {
            populated.insert(BoardFocusZone.prompt)
        }
        if !projection.acts.isEmpty || !projection.agendas.isEmpty {
            populated.insert(BoardFocusZone.actAgenda)
        }
        if !projection.locations.isEmpty {
            populated.insert(BoardFocusZone.locations)
        }
        if !projection.enemyLocations.isEmpty {
            populated.insert(BoardFocusZone.enemyLocations)
        }
        if !projection.investigators.isEmpty {
            populated.insert(BoardFocusZone.investigators)
        }
        return BoardFocusZone.cycleOrder.filter { populated.contains($0) }
    }

    /// Resolves the compact-width zone switcher's selected zone: `focusedZone` if it is
    /// one of `zones` (the switcher's own tags); else `preModalZone` if *that* is still
    /// one of `zones`; else the first of `zones`. The middle case is what keeps the
    /// switcher (and the board content beneath the modal) parked on whatever zone the
    /// user had actually selected for the entire time the inspector is presented, rather
    /// than arbitrarily jumping to the first zone: while the inspector modal is up,
    /// `focusedZone` is always ``BoardFocusZone/inspector`` (never one of `zones`, which
    /// never lists it — see ``nonEmptyZonesInCycleOrder(projection:)``), so without a
    /// remembered `preModalZone` a `Picker` bound to this value would visibly snap away
    /// from the user's actual selection every time they opened an inspector. Falls back
    /// to the first zone only when neither candidate is still valid (for example the
    /// pre-modal zone's last entity was removed by an intervening snapshot replacement),
    /// and to ``BoardFocusZone/scenario`` when `zones` itself is empty, rather than
    /// binding a `Picker`'s `selection` to a value with no matching tag.
    static func resolveCompactSelectedZone(
        focusedZone: SemanticFocusZone?, preModalZone: SemanticFocusZone?,
        zones: [SemanticFocusZone]
    ) -> SemanticFocusZone {
        if let focusedZone, zones.contains(focusedZone) {
            return focusedZone
        }
        if let preModalZone, zones.contains(preModalZone) {
            return preModalZone
        }
        return zones.first ?? BoardFocusZone.scenario
    }

    private static func appendVerticalChain(
        _ ids: [SemanticFocusID], zone: SemanticFocusZone,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !ids.isEmpty else { return }
        for (index, id) in ids.enumerated() {
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            if index > 0 {
                neighbors[.up] = ids[index - 1]
            }
            if index < ids.count - 1 {
                neighbors[.down] = ids[index + 1]
            }
            nodes.append(FocusNode(id: id, zone: zone, neighbors: neighbors))
        }
        zoneEntryPoints[zone] = ids[0]
    }

    private static func appendHorizontalChain(
        _ ids: [SemanticFocusID], zone: SemanticFocusZone,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !ids.isEmpty else { return }
        for (index, id) in ids.enumerated() {
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            if index > 0 {
                neighbors[.left] = ids[index - 1]
            }
            if index < ids.count - 1 {
                neighbors[.right] = ids[index + 1]
            }
            nodes.append(FocusNode(id: id, zone: zone, neighbors: neighbors))
        }
        zoneEntryPoints[zone] = ids[0]
    }
}

// swiftlint:enable type_body_length
