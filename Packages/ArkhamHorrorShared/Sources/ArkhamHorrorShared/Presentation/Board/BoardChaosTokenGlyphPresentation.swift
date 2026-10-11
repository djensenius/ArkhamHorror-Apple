enum BoardChaosTokenGlyphPresentation {
    static let fallbackSystemImage = "circle.hexagongrid.fill"

    static func nodes(for face: ChaosTokenFace) -> [StoryNode]? {
        face.storyIcon.map { [.semanticIcon($0)] }
    }

    static func run(
        for face: ChaosTokenFace,
        iconFonts: WebIconFontAvailability
    ) -> StoryInlineSemanticIconRun {
        guard let icon = face.storyIcon else { return .systemImage(name: fallbackSystemImage) }
        return StoryInlineTextRenderer.semanticIconRun(for: icon, iconFonts: iconFonts)
    }
}
