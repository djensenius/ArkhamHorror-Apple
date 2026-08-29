import SwiftUI

/// The sign-in form: email and password only, matching the backend's `Authentication`
/// contract exactly. The password is local view state, cleared immediately after a
/// successful sign-in and whenever the form disappears; it never enters an alert,
/// identifier, diagnostic, preview, or log. Tapping Cancel calls
/// ``AppModel/cancelAuthOperation(ownedBy:)``, passing this form's own remembered
/// attempt identity (see ``AppModel/currentAuthAttemptID``) so it can only ever cancel
/// the exact sign-in/registration attempt *this form itself* started — `AppModel` is
/// shared process-wide across every window (for example on macOS/visionOS), so a
/// second window's own, unrelated sign-in/registration must never be interrupted by
/// this form's Cancel button, even if it happens to reuse the same profile. Cancelling
/// the in-flight task advances the generation/credential epoch and returns to
/// signed-out — so a slow sign-in or registration the user has already cancelled can
/// never complete and sign them in later. That call is a safe no-op once a sign-in has
/// already succeeded, so it can never undo a just-completed, already-navigated-away-
/// from success. Cancellation's cleanup must itself be durably reserved before this
/// form dismisses: while it could not be (``AppModel/authFailure`` surfaces why, since
/// this failure belongs to this form's own attempt exactly like any other failure
/// here), the form stays open and interactive (swipe) dismissal is disabled —
/// cancellation only ever happens through that button or the sign-in success path
/// above; `onDisappear` deliberately has no side effect beyond clearing the password,
/// because it cannot observe or react to a failed cleanup reservation, and because
/// ``AppModel`` may be shared by more than one window: this form disappearing must
/// never cancel a different window's legitimate, still-wanted sign-in.
///
/// Every credential/network/whoami/token-save/cancellation-reservation failure this
/// form's own attempt produces is attributed to `ownedAttemptID` (via
/// ``AppModel/authFailure``) and only ever rendered here when that ID matches — never
/// via the shared, unattributed ``AppModel/operationFailure`` — so a second,
/// pre-opened or later-opened sign-in/registration form (for the same or a different
/// profile) never displays a failure it did not itself cause, and a stale attempt's
/// late-arriving failure can never overwrite what a newer attempt reusing the same
/// profile/kind should show.
struct SignInView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var ownedAttemptID: UUID?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case password
    }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .emailFieldStyle()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier(AccountAccessibilityID.emailField)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier(AccountAccessibilityID.passwordField)
            } footer: {
                if let failure = ownedFailure {
                    ArkhamFailureText(message: failure.message)
                }
            }

            Section {
                ArkhamPrimaryButton(
                    "Sign In",
                    systemImage: "arrow.right.circle.fill",
                    isLoading: model.operation == .signingIn,
                    action: submit
                )
                .disabled(!isValid || model.operation != .idle)
                .accessibilityIdentifier(AccountAccessibilityID.signInSubmitButton)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Sign In")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    // Only dismiss once cancellation's cleanup reservation actually
                    // succeeded; a `false` result means a genuinely active operation
                    // this form itself owns could not be safely interrupted, so the
                    // form must stay open with its typed failure visible rather than
                    // abandoning an unprotected in-flight save. Passing
                    // `ownedAttemptID` (rather than an unconditional, process-global
                    // cancel) ensures this can only ever affect the attempt this form
                    // itself started — never a different window's own sign-in that
                    // happens to reuse the same profile.
                    if model.cancelAuthOperation(ownedBy: ownedAttemptID) {
                        dismiss()
                    }
                }
            }
        }
        // Disabled for as long as there is an active sign-in this form's dismissal
        // would need to safely cancel first — forcing that through the Cancel button
        // above (which observes the reservation's outcome) rather than an interactive
        // swipe that cannot observe or react to a failed reservation.
        .interactiveDismissDisabled(model.operation == .signingIn)
        .onAppear { focusedField = .email }
        .onChange(of: model.sessionState) { _, newValue in
            guard case .signedIn = newValue else { return }
            password = ""
            dismiss()
        }
        .onDisappear {
            // Deliberately side-effect-free beyond clearing the password: it cannot
            // observe or react to a failed cleanup reservation the way the Cancel
            // button above can, and `AppModel` may be shared by more than one window,
            // so this form disappearing must never cancel a different window's
            // legitimate, still-wanted sign-in. Cancellation only ever happens through
            // the explicit Cancel button or the sign-in success path above.
            password = ""
        }
    }

    private var isValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// This form's own attempt's failure, or `nil` if it never submitted or its
    /// current failure (if any) belongs to a different attempt entirely — see this
    /// type's own documentation for why only exact-attempt matches are ever rendered.
    private var ownedFailure: SessionOperationFailure? {
        guard let ownedAttemptID, let failure = model.authFailure,
              failure.attemptID == ownedAttemptID
        else { return nil }
        return failure.failure
    }

    private func submit() {
        guard isValid, model.operation == .idle else { return }
        ownedAttemptID = model.signIn(AuthenticationCredentials(email: email, password: password))
    }
}

/// The registration form: email, username, and password, matching the backend's
/// `Registration` contract exactly with no additional client-invented fields (such as a
/// password-confirmation field the backend does not require). The password is local
/// view state with the same clearing behavior as ``SignInView``, and `onDisappear` is
/// likewise side-effect-free beyond clearing it — see the matching comment in
/// ``SignInView``.
struct RegisterView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var ownedAttemptID: UUID?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email
        case username
        case password
    }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .emailFieldStyle()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .username }
                    .accessibilityIdentifier(AccountAccessibilityID.emailField)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .usernameFieldStyle()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier(AccountAccessibilityID.usernameField)

                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier(AccountAccessibilityID.passwordField)
            } footer: {
                if let failure = ownedFailure {
                    ArkhamFailureText(message: failure.message)
                }
            }

            Section {
                ArkhamPrimaryButton(
                    "Create Account",
                    systemImage: "person.badge.plus",
                    isLoading: model.operation == .registering,
                    action: submit
                )
                .disabled(!isValid || model.operation != .idle)
                .accessibilityIdentifier(AccountAccessibilityID.registerSubmitButton)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Create Account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    // See the matching comment in `SignInView`: only dismiss once
                    // cancellation's cleanup reservation actually succeeded, and only
                    // this form's own remembered attempt can ever be the one cancelled.
                    if model.cancelAuthOperation(ownedBy: ownedAttemptID) {
                        dismiss()
                    }
                }
            }
        }
        // See the matching comment in `SignInView`.
        .interactiveDismissDisabled(model.operation == .registering)
        .onAppear { focusedField = .email }
        .onChange(of: model.sessionState) { _, newValue in
            guard case .signedIn = newValue else { return }
            password = ""
            dismiss()
        }
        .onDisappear {
            // Deliberately side-effect-free beyond clearing the password; see the
            // matching comment in `SignInView`.
            password = ""
        }
    }

    private var isValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    /// This form's own attempt's failure, or `nil` if it never submitted or its
    /// current failure (if any) belongs to a different attempt entirely — see this
    /// type's own documentation for why only exact-attempt matches are ever rendered.
    private var ownedFailure: SessionOperationFailure? {
        guard let ownedAttemptID, let failure = model.authFailure,
              failure.attemptID == ownedAttemptID
        else { return nil }
        return failure.failure
    }

    private func submit() {
        guard isValid, model.operation == .idle else { return }
        ownedAttemptID = model.register(
            RegistrationDetails(email: email, username: username, password: password)
        )
    }
}

#Preview("Sign In") {
    NavigationStack {
        SignInView(model: previewAppModel())
    }
}

#Preview("Create Account") {
    NavigationStack {
        RegisterView(model: previewAppModel())
    }
}
