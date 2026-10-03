import Observation
import SwiftUI

@MainActor
@Observable
final class JoinGameInviteViewModel {
    var inviteText = ""
    private(set) var isSubmitting = false
    private(set) var failureMessage: String?

    var canSubmit: Bool {
        !isSubmitting && !inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func submit(joinInvite: (GameID) async throws -> GameID) async -> GameID? {
        guard !isSubmitting else { return nil }
        isSubmitting = true
        failureMessage = nil
        defer { isSubmitting = false }

        let invite: GameInvite
        do {
            invite = try GameInvite.parse(inviteText)
        } catch {
            failureMessage = gameLifecycleLocalized(
                "games.joinInvite.error.invalid",
                "Enter a game invite link or game ID."
            )
            return nil
        }

        do {
            return try await joinInvite(invite.gameID)
        } catch is CancellationError {
            return nil
        } catch let error as GameLifecycleError {
            failureMessage = error.message
            return nil
        } catch {
            failureMessage = gameLifecycleLocalized(
                "games.joinInvite.error.generic",
                "Couldn't join that game. Try again."
            )
            return nil
        }
    }
}

struct JoinGameInviteSheetView: View {
    let model: AppModel
    let onJoined: (GameID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = JoinGameInviteViewModel()

    var body: some View {
        Form {
            Section {
                TextField(
                    gameLifecycleLocalized(
                        "games.joinInvite.placeholder",
                        "https://arkhamhorror.app/games/.../join"
                    ),
                    text: Binding(
                        get: { viewModel.inviteText },
                        set: { viewModel.inviteText = $0 }
                    )
                )
                .textContentType(.URL)
                #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                    .autocorrectionDisabled()
                    .disabled(viewModel.isSubmitting)
                    .accessibilityLabel(gameLifecycleLocalized(
                        "games.joinInvite.field.accessibility",
                        "Game invite link or ID"
                    ))
                    .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteField)
            } header: {
                Text(gameLifecycleLocalized("games.joinInvite.section", "Invite"))
            } footer: {
                Text(gameLifecycleLocalized(
                    "games.joinInvite.footer",
                    "Paste the web invite link, or just the game ID. The server "
                        + "decides whether you may join."
                ))
            }

            if let failure = viewModel.failureMessage {
                Section {
                    ArkhamFailureText(message: failure)
                        .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteFailureText)
                }
            }
        }
        .navigationTitle(gameLifecycleLocalized("games.joinInvite.title", "Join Game"))
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
        .interactiveDismissDisabled(viewModel.isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(gameLifecycleLocalized("common.cancel", "Cancel")) {
                    dismiss()
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteCancelButton)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text(gameLifecycleLocalized("games.joinInvite.submit", "Join"))
                    }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteSubmitButton)
            }
        }
    }

    private func submit() async {
        guard let id = await viewModel.submit(joinInvite: { gameID in
            try await model.joinGameFromInvite(gameID)
        }) else { return }
        onJoined(id)
        dismiss()
    }
}
