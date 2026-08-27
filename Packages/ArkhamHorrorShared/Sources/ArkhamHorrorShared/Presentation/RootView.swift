import SwiftUI

public struct RootView: View {
    @State private var model = AppModel()
    @FocusState private var focusedTarget: AppCommandTarget?

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
                    serverStatusButton
                    placeholder
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            focusedTarget = .serverStatus
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ARKHAM HORROR")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .tracking(2)

            Text("A semantic digital card game")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.68))
        }
        .accessibilityElement(children: .combine)
    }

    private var serverStatusButton: some View {
        Button {
            model.send(AppCommandTarget.serverStatus.command)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.mint)
                    .frame(width: 44, height: 44)
                    .background(.mint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.serverStatus.title)
                        .font(.headline)
                    Text(model.serverStatus.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                Image(systemName: "chevron.forward")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        focusedTarget == .serverStatus ? Color.mint : .white.opacity(0.12),
                        lineWidth: focusedTarget == .serverStatus ? 3 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .serverStatus)
        .accessibilityHint("Opens server configuration when that feature is available")
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Foundation ready")
                .font(.title2.bold())

            Text(
                "Shared presentation, semantic commands, and native focus navigation "
                    + "are connected. Gameplay will be built on this foundation."
            )
            .foregroundStyle(.white.opacity(0.72))

            Button {
                model.send(AppCommandTarget.primaryAction.command)
            } label: {
                Label("New campaign", systemImage: "plus.circle.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .focused($focusedTarget, equals: .primaryAction)
            .accessibilityHint("Confirms that game setup is not yet implemented")

            Text(model.message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
    }
}
