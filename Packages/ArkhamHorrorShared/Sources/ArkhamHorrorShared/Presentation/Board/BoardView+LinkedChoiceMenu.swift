import SwiftUI

extension BoardView {
    func linkedChoiceMenuBinding(_ controller: BoardCommandController) -> Binding<Bool> {
        Binding(
            get: { controller.linkedChoiceMenuRequest != nil },
            set: { isPresented in
                if !isPresented {
                    controller.clearLinkedChoiceMenuRequest()
                }
            }
        )
    }

    @ViewBuilder
    func linkedChoiceMenuButtons(_ controller: BoardCommandController) -> some View {
        if let request = controller.linkedChoiceMenuRequest {
            ForEach(request.choices, id: \.choiceIndex) { choice in
                Button(choice.title) {
                    controller.clearLinkedChoiceMenuRequest()
                    controller.activatePromptChoice(choice.choiceIndex)
                }
            }
        }
    }
}
