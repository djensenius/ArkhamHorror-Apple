import SwiftUI

/// The sign-in form: email and password only, matching the backend's `Authentication`
/// contract exactly. The password is local view state, cleared immediately after a
/// successful sign-in and whenever the form disappears; it never enters an alert,
/// identifier, diagnostic, preview, or log. Tapping Cancel calls
/// ``AppModel/cancelAuthOperation()``, which cancels the in-flight task, advances the
/// generation/credential epoch, and returns to signed-out — so a slow sign-in or
/// registration the user has already cancelled can never complete and sign them in
/// later. That call is a safe no-op once a sign-in has already succeeded, so it can
/// never undo a just-completed, already-navigated-away-from success. Cancellation's
/// cleanup must itself be durably reserved before this form dismisses: while it could
/// not be (``AppModel/operationFailure`` surfaces why), the form stays open and
/// interactive (swipe) dismissal is disabled — `onDisappear` is only a defensive,
/// idempotent follow-up rather than the sole path that can ever release the operation.
struct SignInView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
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
                if let failure = model.operationFailure {
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
                    // could not be safely interrupted, so the form must stay open
                    // with its typed failure visible rather than abandoning an
                    // unprotected in-flight save.
                    if model.cancelAuthOperation() {
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
            // Defensive and idempotent only: normal dismissal always goes through the
            // Cancel button or the sign-in success path above, both of which already
            // reserve cleanup (or need none). This exists solely to catch dismissal
            // paths this view does not otherwise control (e.g. a parent navigating
            // away); it must never be the only place cleanup is attempted.
            password = ""
            model.cancelAuthOperation()
        }
    }

    private var isValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func submit() {
        guard isValid, model.operation == .idle else { return }
        model.signIn(AuthenticationCredentials(email: email, password: password))
    }
}

/// The registration form: email, username, and password, matching the backend's
/// `Registration` contract exactly with no additional client-invented fields (such as a
/// password-confirmation field the backend does not require). The password is local
/// view state with the same clearing behavior as ``SignInView``.
struct RegisterView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
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
                if let failure = model.operationFailure {
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
                    // cancellation's cleanup reservation actually succeeded.
                    if model.cancelAuthOperation() {
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
            // Defensive and idempotent only; see the matching comment in `SignInView`.
            password = ""
            model.cancelAuthOperation()
        }
    }

    private var isValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private func submit() {
        guard isValid, model.operation == .idle else { return }
        model.register(
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
