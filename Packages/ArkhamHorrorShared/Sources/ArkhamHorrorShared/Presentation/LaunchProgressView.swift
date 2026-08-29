import SwiftUI

/// The native progress presentation shown while profiles are loading or the selected
/// server's compatibility/token restoration is in flight.
///
/// Shown for both ``AccountRoute/launch(profileName:)`` sub-cases so no prior screen's
/// content (a stale server list or account shell) is ever left on screen while a fresh
/// check is under way.
struct LaunchProgressView: View {
    let profileName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(ArkhamTheme.accent)

            VStack(spacing: 6) {
                Text("Checking your server")
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                if let profileName {
                    Text(profileName)
                        .font(.subheadline)
                        .foregroundStyle(ArkhamTheme.bone.opacity(0.7))
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(reduceMotion ? .identity : .opacity)
    }
}

#Preview("Launch – no profile yet") {
    LaunchProgressView(profileName: nil)
        .background(ArkhamTheme.backgroundGradient)
}

#Preview("Launch – checking a named server") {
    LaunchProgressView(profileName: "Arkham Horror Online")
        .background(ArkhamTheme.backgroundGradient)
}
