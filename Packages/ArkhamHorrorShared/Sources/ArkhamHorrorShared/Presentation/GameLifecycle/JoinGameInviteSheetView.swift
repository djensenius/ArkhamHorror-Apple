import Observation
import SwiftUI

typealias ClaimSeatInviteViewState = ClaimSeatInviteDetails

@MainActor
@Observable
final class JoinGameInviteViewModel {
    var inviteText = "" {
        didSet {
            if inviteText != oldValue {
                inviteInputRevision += 1
                claimSeatInvite = nil
            }
        }
    }

    private var inviteInputRevision = 0
    private(set) var isSubmitting = false
    private(set) var claimingSeat: CardCode?
    private(set) var failureMessage: String?
    private(set) var claimSeatInvite: ClaimSeatInviteViewState?

    var canSubmit: Bool {
        !isSubmitting
            && claimingSeat == nil
            && !inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func submit(
        joinInvite: (GameID) async throws -> GameID,
        loadClaimSeatInvite: (GameID) async throws -> ClaimSeatInviteViewState
    ) async -> GameID? {
        guard !isSubmitting, claimingSeat == nil else { return nil }
        isSubmitting = true
        failureMessage = nil
        claimSeatInvite = nil
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

        let submittedInviteRevision = inviteInputRevision
        do {
            switch invite.route {
            case .join:
                return try await joinInvite(invite.gameID)
            case .claimSeat:
                let loadedInvite = try await loadClaimSeatInvite(invite.gameID)
                guard inviteInputRevision == submittedInviteRevision else { return nil }
                claimSeatInvite = loadedInvite
                return nil
            }
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

    @discardableResult
    func claimSeat(
        _ seat: CardCode,
        claimSeatInvite: (CardCode, ClaimSeatInviteViewState) async throws -> GameID,
        reloadClaimSeatInvite: (GameID) async throws -> ClaimSeatInviteViewState
    ) async -> GameID? {
        guard claimingSeat == nil, let invite = self.claimSeatInvite else { return nil }
        let submittedInviteRevision = inviteInputRevision
        claimingSeat = seat
        failureMessage = nil
        defer { claimingSeat = nil }

        do {
            return try await claimSeatInvite(seat, invite)
        } catch is CancellationError {
            return nil
        } catch let error as GameLifecycleError {
            failureMessage = error.message
            if let refreshedInvite = try? await reloadClaimSeatInvite(invite.gameID) {
                guard inviteInputRevision == submittedInviteRevision else { return nil }
                self.claimSeatInvite = refreshedInvite
            }
            return nil
        } catch {
            failureMessage = gameLifecycleLocalized(
                "games.joinInvite.error.generic",
                "Couldn't join that game. Try again."
            )
            if let refreshedInvite = try? await reloadClaimSeatInvite(invite.gameID) {
                guard inviteInputRevision == submittedInviteRevision else { return nil }
                self.claimSeatInvite = refreshedInvite
            }
            return nil
        }
    }

    @discardableResult
    func continueFromClaimSeatInvite(
        refreshInvite: (ClaimSeatInviteViewState) async throws -> GameID
    ) async -> GameID? {
        guard !isSubmitting, claimingSeat == nil, let invite = claimSeatInvite else { return nil }
        isSubmitting = true
        failureMessage = nil
        defer { isSubmitting = false }

        do {
            return try await refreshInvite(invite)
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
            inviteInputSection
            claimSeatSection
            failureSection
        }
        .navigationTitle(gameLifecycleLocalized("games.joinInvite.title", "Join Game"))
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
        .interactiveDismissDisabled(viewModel.isSubmitting || viewModel.claimingSeat != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(gameLifecycleLocalized("common.cancel", "Cancel")) {
                    dismiss()
                }
                .disabled(viewModel.isSubmitting || viewModel.claimingSeat != nil)
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

    private var inviteInputSection: some View {
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
                .disabled(viewModel.isSubmitting || viewModel.claimingSeat != nil)
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
    }

    @ViewBuilder
    private var claimSeatSection: some View {
        if let invite = viewModel.claimSeatInvite {
            Section {
                claimSeatContent(for: invite)
            } header: {
                Text(gameLifecycleLocalized("games.joinInvite.openSeats.section", "Open Seats"))
            } footer: {
                Text(gameLifecycleLocalized(
                    "games.joinInvite.openSeats.footer",
                    "Choose one of the server's open seats."
                ))
            }
        }
    }

    @ViewBuilder
    private func claimSeatContent(for invite: ClaimSeatInviteViewState) -> some View {
        if invite.viewerHasSeat {
            Text(gameLifecycleLocalized(
                "games.lobby.openSeats.alreadyClaimed",
                "You already have a seat in this game."
            ))
            .foregroundStyle(.secondary)
            if invite.canContinue {
                continueButton(for: invite)
            }
        } else if invite.seats.isEmpty {
            Text(gameLifecycleLocalized(
                "games.lobby.openSeats.empty",
                "No open seats remain."
            ))
            .foregroundStyle(.secondary)
        } else if invite.showsClaimButtons {
            claimSeatButtons(for: invite)
        }
    }

    private func claimSeatButtons(for invite: ClaimSeatInviteViewState) -> some View {
        ForEach(invite.seats, id: \.rawValue) { seat in
            Button {
                Task { await claimSeat(seat) }
            } label: {
                HStack {
                    Label(
                        gameLifecycleLocalizedFormat(
                            "games.joinInvite.claimSeat",
                            "Claim %@",
                            seat.rawValue
                        ),
                        systemImage: "person.fill.badge.plus"
                    )
                    if viewModel.claimingSeat == seat {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(viewModel.claimingSeat != nil || viewModel.isSubmitting)
            .accessibilityIdentifier(
                AccountAccessibilityID.gameClaimSeatButton(
                    for: invite.gameID.rawValue,
                    seat: seat.rawValue
                )
            )
        }
    }

    private func continueButton(for invite: ClaimSeatInviteViewState) -> some View {
        Button {
            Task { await continueFromClaimSeatInvite() }
        } label: {
            Label(
                gameLifecycleLocalized("games.lobby.continue", "Continue"),
                systemImage: "arrow.right.circle.fill"
            )
        }
        .disabled(viewModel.isSubmitting || viewModel.claimingSeat != nil)
        .accessibilityIdentifier(
            AccountAccessibilityID.liveGameEnterButton(for: invite.gameID.rawValue)
        )
    }

    @ViewBuilder
    private var failureSection: some View {
        if let failure = viewModel.failureMessage {
            Section {
                ArkhamFailureText(message: failure)
                    .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteFailureText)
            }
        }
    }

    private func submit() async {
        guard let id = await viewModel.submit(
            joinInvite: { gameID in
                try await model.joinGameFromInvite(gameID)
            },
            loadClaimSeatInvite: { gameID in
                try await model.loadClaimSeatInvite(gameID)
            }
        ) else { return }
        onJoined(id)
        dismiss()
    }

    private func claimSeat(_ seat: CardCode) async {
        guard let id = await viewModel.claimSeat(
            seat,
            claimSeatInvite: { seat, invite in
                try await model.claimSeatFromInvite(seat, using: invite)
            },
            reloadClaimSeatInvite: { gameID in
                try await model.loadClaimSeatInvite(gameID)
            }
        ) else { return }
        onJoined(id)
        dismiss()
    }

    private func continueFromClaimSeatInvite() async {
        guard let id = await viewModel.continueFromClaimSeatInvite(refreshInvite: { invite in
            try await model.continueClaimSeatInvite(using: invite)
        }) else { return }
        onJoined(id)
        dismiss()
    }
}
