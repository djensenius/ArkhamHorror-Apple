@testable import ArkhamHorrorShared

enum GenericSingleChoiceRawQuestionFixtures {
    static func directQuestion(tag: String, count: Int) -> JSONValue {
        .object([
            "tag": .string(tag),
            "choices": .array((0 ..< count).map { rawLabel("$choice.\($0)") }),
        ])
    }

    static func chooseSome1Question() -> JSONValue {
        // Arkham/Question.hs:196 declares ChooseSome1's raw label/choices fields;
        // Arkham/Question/Presentation.hs:463-470 adds selection and completionLabel.
        .object([
            "tag": .string("ChooseSome1"),
            "label": .string("$done"),
            "choices": .array([rawLabel("$a"), rawDone("$done")]),
        ])
    }

    static func chooseOneWizardQuestion() -> JSONValue {
        // Arkham/Question.hs:156-159 and 234-238 define WizardChoice and
        // ChooseOneWizard; Arkham/Question/Presentation.hs:528-533 binds
        // wizardChoices to source-indexed wizardChoice descriptors.
        .object([
            "tag": .string("ChooseOneWizard"),
            "flavorText": flavorText(),
            "wizardChoices": .array([rawWizardChoice("$wizard")]),
            "confirmLabel": .string("$confirm"),
            "backLabel": .string("$back"),
        ])
    }

    private static func rawLabel(_ label: String) -> JSONValue {
        .object([
            "tag": .string("Label"),
            "label": .string(label),
            "messages": .array([]),
        ])
    }

    private static func rawDone(_ label: String) -> JSONValue {
        .object([
            "tag": .string("Done"),
            "label": .string(label),
        ])
    }

    private static func rawWizardChoice(_ label: String) -> JSONValue {
        .object([
            "label": .string(label),
            "flavorText": flavorText(),
            "messages": .array([]),
        ])
    }

    private static func flavorText() -> JSONValue {
        .object(["title": .null, "body": .array([])])
    }
}
