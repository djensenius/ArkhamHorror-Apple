/// The normalized, backend-canonical deck list shape: all nine keys are always present,
/// `slots`/`sideSlots` keys are validated `CardCode`s, and `investigatorCode` is a validated
/// `CardCode`-patterned string.
struct DeckList: Sendable, Equatable, Codable {
    private enum CodingKeys: String, CodingKey {
        case slots
        case sideSlots
        case investigatorCode = "investigator_code"
        case investigatorName = "investigator_name"
        case meta
        case tabooId = "taboo_id"
        case url
        case id
        case name
    }

    let slots: CardQuantityMap
    let sideSlots: CardQuantityMap
    let investigatorCode: CardCode
    let investigatorName: String
    let meta: String?
    let tabooId: Int?
    let url: String?
    let id: String?
    let name: String?
}
