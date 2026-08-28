import SwiftUI

/// The shared root view for every platform target.
///
/// This is intentionally a thin status readout over ``AppModel``: it surfaces the
/// current ``SessionState`` and offers retry/sign-out actions. Dedicated sign-in,
/// registration, and server-management forms are tracked separately.
public struct RootView: View {
    @State private var model = AppModel()
    @FocusState private var isPrimaryActionFocused: Bool

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.09),
                    Color(red: 0.10, green: 0.12, blue: 0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    brand
                    statusCard
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            isPrimaryActionFocused = true
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ARKHAM HORROR")
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .tracking(2)

            Text("A semantic digital card game")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.68))
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: statusIconName)
                    .font(.title2)
                    .foregroundStyle(.mint)
                    .frame(width: 44, height: 44)
                    .background(.mint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.sessionState.title)
                        .font(.headline)
                    Text(model.sessionState.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()
            }

            primaryAction

            if let operationFailure = model.operationFailure {
                Text(operationFailure.message)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.sessionState.isRetryable {
            Button {
                model.retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .focused($isPrimaryActionFocused)
            .accessibilityHint("Retries checking the selected server")
        } else if case .signedIn = model.sessionState {
            Button {
                model.signOut()
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.bordered)
            .focused($isPrimaryActionFocused)
            .accessibilityHint("Signs out of the current server")
        }
    }

    private var statusIconName: String {
        switch model.sessionState {
        case .signedIn:
            "checkmark.circle.fill"
        case .incompatible, .unavailable, .storageCorrupted:
            "exclamationmark.triangle.fill"
        case .launching, .checkingCompatibility, .signedOut:
            "network"
        }
    }
}
