@testable import ArkhamHorrorShared
import Testing

@Suite("Story icon variable values")
struct StoryIconVariableValueTests {
    private struct IconExpectation {
        let raw: String
        let icon: StoryIcon
        let systemImage: String
        let accessibilityLabel: String
    }

    private static let tokenCases: [(String, StoryIcon)] = [
        ("skull", .chaosToken(.skull)),
        ("cultist", .chaosToken(.cultist)),
        ("tablet", .chaosToken(.tablet)),
        ("elderThing", .chaosToken(.elderThing)),
        ("autoFail", .chaosToken(.autoFail)),
        ("elderSign", .chaosToken(.elderSign)),
        ("curse", .chaosToken(.curse)),
        ("bless", .chaosToken(.bless)),
        ("frost", .chaosToken(.frost)),
        ("blood", .chaosToken(.blood)),
    ]

    private static let semanticIconCases = [
        IconExpectation(
            raw: "willpower", icon: .skill(.willpower),
            systemImage: "brain.head.profile", accessibilityLabel: "willpower"
        ),
        IconExpectation(
            raw: "intellect", icon: .skill(.intellect),
            systemImage: "magnifyingglass", accessibilityLabel: "intellect"
        ),
        IconExpectation(
            raw: "combat", icon: .skill(.combat),
            systemImage: "burst.fill", accessibilityLabel: "combat"
        ),
        IconExpectation(
            raw: "agility", icon: .skill(.agility),
            systemImage: "figure.run", accessibilityLabel: "agility"
        ),
        IconExpectation(
            raw: "wild", icon: .skill(.wild),
            systemImage: "star.fill", accessibilityLabel: "wild"
        ),
        IconExpectation(
            raw: "sealA", icon: .seal(.sealA),
            systemImage: "a.circle.fill", accessibilityLabel: "seal a"
        ),
        IconExpectation(
            raw: "sealB", icon: .seal(.sealB),
            systemImage: "b.circle.fill", accessibilityLabel: "seal b"
        ),
        IconExpectation(
            raw: "sealC", icon: .seal(.sealC),
            systemImage: "c.circle.fill", accessibilityLabel: "seal c"
        ),
        IconExpectation(
            raw: "sealD", icon: .seal(.sealD),
            systemImage: "d.circle.fill", accessibilityLabel: "seal d"
        ),
        IconExpectation(
            raw: "sealE", icon: .seal(.sealE),
            systemImage: "e.circle.fill", accessibilityLabel: "seal e"
        ),
    ]

    @Test("Icon variables accept exactly the governed token, skill, and seal tables")
    func iconVariableValueTable() {
        for (raw, icon) in Self.tokenCases {
            #expect(StoryIcon.iconVariableValue(raw) == icon)
        }
        for expected in Self.semanticIconCases {
            let icon = StoryIcon.iconVariableValue(expected.raw)
            #expect(icon == expected.icon)
            #expect(icon?.systemImage == expected.systemImage)
            #expect(icon?.accessibilityLabel == expected.accessibilityLabel)
        }
        #expect(StoryIcon.iconVariableValue("elderthing") == nil)
        #expect(StoryIcon.iconVariableValue("wildMinus") == nil)
        #expect(StoryIcon.iconVariableValue("sealF") == nil)
    }
}
