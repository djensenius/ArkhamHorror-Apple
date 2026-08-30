import SwiftUI

/// A focusable, inspectable board entity tile: every zone view (scenario header, act/
/// agenda rows, location cards, investigator cards, the chaos bag summary) wraps its
/// content in exactly this control, so every entity on the board is reachable by the same
/// ``SemanticActionControl`` seam (touch, pointer, keyboard, Siri Remote, controller, and
/// visionOS focus/gaze) with no bespoke per-zone gesture code.
struct BoardEntityTile<Content: View>: View {
    let id: SemanticFocusID
    let accessibilityLabel: String
    let isFocused: Bool
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        SemanticActionControl(
            accessibilityLabel: Text(accessibilityLabel),
            semanticFocusID: id,
            onOutcome: onOutcome,
            label: {
                content()
                    .padding(10)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(tileBackground)
                    .overlay(focusOutline)
            }
        )
        .buttonStyle(.plain)
        .focused(focusBinding, equals: id)
    }

    @ViewBuilder private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(white: 0.16))
        } else {
            shape.fill(.thinMaterial)
        }
    }

    private var focusOutline: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isFocused ? ArkhamTheme.accent : Color.clear, lineWidth: 3)
    }
}

/// A small label/value pill used for compact stats (health, sanity, actions, doom,
/// clues, ...). Purely decorative text; the containing tile's own accessibility label
/// already carries the equivalent information in sentence form.
struct BoardStatBadge: View {
    let systemImage: String
    let value: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.25), in: Capsule())
            .accessibilityHidden(true)
    }
}

/// A small section heading used above each board zone.
struct BoardSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(ArkhamTheme.bone)
            .addingBoardHeadingTrait()
    }
}

private extension View {
    /// `.isHeader` is unavailable on tvOS in some toolchains; apply it only where
    /// supported, mirroring ``ArkhamHeader``'s identical guard.
    @ViewBuilder
    func addingBoardHeadingTrait() -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
            accessibilityAddTraits(.isHeader)
        #else
            self
        #endif
    }
}
