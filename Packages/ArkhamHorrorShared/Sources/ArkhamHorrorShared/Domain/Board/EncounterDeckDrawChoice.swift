extension BasicChoiceParser {
    /// Revision 0.1.30's closed encounterDeckDrawLabel branch, not a general DrawCards decoder.
    /// This validates wire shape only; the backend executes the unchanged source-index answer.
    static func parseEncounterDeckDraw(
        _ object: [String: JSONValue], kind: BasicChoiceQuestionKind, index: Int
    ) -> BasicChoiceContent? {
        guard kind == .chooseOne, index == 0,
              Set(object.keys) == ["tag", "target", "messages"],
              object["tag"] == .string("TargetLabel"),
              object["target"] == .object(["tag": .string("EncounterDeckTarget")]),
              case let .array(messages)? = object["messages"],
              messages.count == 1,
              case let .object(message) = messages[0],
              Set(message.keys) == ["tag", "contents"],
              message["tag"] == .string("DrawCards"),
              case let .array(contents)? = message["contents"],
              contents.count == 2,
              case let .string(rawInvestigatorID) = contents[0],
              let cardCode = strictCardCode(rawInvestigatorID),
              case let .object(draw) = contents[1],
              case let .number(amount)? = draw["cardDrawAmount"],
              amount.rawToken == "1",
              draw == [
                  "cardDrawAction": .bool(false),
                  "cardDrawAlreadyDrawn": .array([]),
                  "cardDrawAmount": .number(amount),
                  "cardDrawAndThen": .null,
                  "cardDrawDeck": .object(["tag": .string("EncounterDeck")]),
                  "cardDrawDiscard": .null,
                  "cardDrawKind": .string("StandardCardDraw"),
                  "cardDrawPosition": .string("DrawFromTop"),
                  "cardDrawRules": .array([]),
                  "cardDrawSource": .object(["tag": .string("GameSource")]),
                  "cardDrawState": .object(["tag": .string("UnresolvedCardDraw")]),
                  "cardDrawTarget": .null,
              ]
        else { return nil }
        return .drawEncounterCard(investigatorID: InvestigatorID(cardCode), messages: messages)
    }
}
