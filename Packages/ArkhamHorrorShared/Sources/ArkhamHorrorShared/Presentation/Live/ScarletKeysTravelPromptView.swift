import SwiftUI

struct ScarletKeysTravelPromptView: View {
    let prompt: ScarletKeysTravelPromptPresentation
    let canSubmit: Bool
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scarletKeysTravelLocalized(
                "scarletKeysTravel.instructions",
                "Choose a destination on the world map."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("liveGame.prompt.scarletKeysTravel.instructions")

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(prompt.locations) { location in
                        locationRow(location)
                    }
                }
            }
            .frame(maxHeight: 420)
            .accessibilityIdentifier("liveGame.prompt.scarletKeysTravel.locations")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.scarletKeysTravel")
    }

    private func locationRow(
        _ location: ScarletKeysTravelPromptPresentation.Location
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title ?? scarletKeysTravelLocalized(
                        "scarletKeysTravel.locationTextUnavailable",
                        "Location text unavailable"
                    ))
                    .font(.headline)
                    if let subtitle = location.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let travelTimeLabel = prompt.travelTimeLabel
                if let travelTime = location.travelTime, let travelTimeLabel {
                    Text("\(travelTimeLabel): \(travelTime)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(travelTimeLabel): \(travelTime)")
                }
            }

            if location.isCurrent, location.actions.isEmpty {
                Label(
                    scarletKeysTravelLocalized(
                        "scarletKeysTravel.currentLocation",
                        "You are currently here."
                    ),
                    systemImage: "mappin.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !location.actions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(location.actions) { action in
                        actionButton(action, locationTitle: location.title)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.scarletKeysTravel.location.\(location.id)")
    }

    @ViewBuilder
    private func actionButton(
        _ action: ScarletKeysTravelPromptPresentation.Action,
        locationTitle: String?
    ) -> some View {
        let focusID = BoardFocusID.promptScarletKeysTravelAction(action)
        let title = action.title ?? scarletKeysTravelLocalized(
            "scarletKeysTravel.actionTextUnavailable",
            "Action text unavailable"
        )
        let control = SemanticActionControl(
            accessibilityLabel: Text(accessibilityLabel(
                title: title,
                locationTitle: locationTitle
            )),
            semanticFocusID: focusID,
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: {
                Label(title, systemImage: systemImage(for: action.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .focused(focusBinding, equals: focusID)
        .disabled(!canSubmit || !action.isActionable)
        .accessibilityHint(scarletKeysTravelLocalized(
            "scarletKeysTravel.action.hint",
            "Submits this travel choice."
        ))
        .accessibilityIdentifier("liveGame.prompt.scarletKeysTravel.action.\(action.id)")
        if action.kind == .travel {
            control.buttonStyle(.borderedProminent)
        } else {
            control.buttonStyle(.bordered)
        }
    }

    private func accessibilityLabel(title: String, locationTitle: String?) -> String {
        guard let locationTitle else { return title }
        return "\(title): \(locationTitle)"
    }

    private func systemImage(for kind: ScarletKeysTravelPromptPresentation.Action.Kind) -> String {
        switch kind {
        case .travel:
            "mappin.and.ellipse"
        case .travelVia:
            "arrow.triangle.turn.up.right.diamond"
        case .travelWithTicket:
            "ticket.fill"
        }
    }
}

func scarletKeysTravelLocalized(
    _ key: String,
    _ fallback: String,
    _ arguments: CVarArg...
) -> String {
    let format = CampaignPromptLocalization.localized(key, fallback)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}
