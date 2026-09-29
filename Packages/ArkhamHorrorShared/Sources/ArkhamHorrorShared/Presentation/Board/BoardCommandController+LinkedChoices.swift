@MainActor
extension BoardCommandController {
    var focusedBoardChoiceIndex: Int? {
        guard let focused = coordinator.currentFocus else { return nil }
        let choices = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
            .first { $0.key.focusID == focused }?.value
            .filter(\.isActionable) ?? []
        return choices.count == 1 ? choices[0].choiceIndex : nil
    }
}
