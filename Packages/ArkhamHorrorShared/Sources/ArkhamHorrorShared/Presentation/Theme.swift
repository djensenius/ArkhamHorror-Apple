import SwiftUI

/// Shared visual language for the account/server presentation: a dark teal/black,
/// aged-gold/bone palette expressed through semantic SwiftUI materials and colors so it
/// automatically adapts to platform, contrast, and accessibility settings rather than
/// hard-coding a fixed appearance.
///
/// This is intentionally restrained (no custom fonts, imagery, or branded assets) since
/// it is not the final brand/icon pass; it exists to keep this slice visually coherent
/// with the intended direction while every control stays a native, system-styled one.
enum ArkhamTheme {
    /// The deep teal/black background wash used behind every top-level screen.
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.07, blue: 0.09),
            Color(red: 0.09, green: 0.12, blue: 0.12),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The aged-gold accent used for primary actions and emphasis. A fixed, deliberate
    /// brand tone rather than the system accent, so it renders consistently regardless
    /// of the user's chosen system accent color.
    static let accent = Color(red: 0.78, green: 0.66, blue: 0.36)

    /// The warm "bone" foreground tone used for de-emphasized supporting text.
    static let bone = Color(red: 0.90, green: 0.87, blue: 0.78)
}

/// A restrained card container using a semantic system material (rather than a fixed
/// color) so it stays legible across light/dark/increased-contrast settings, with
/// generous internal padding that does not clip Dynamic Type text.
struct ArkhamCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A page title/subtitle header shared by every top-level screen, sized and traited for
/// VoiceOver as a single combined heading element.
struct ArkhamHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.title, design: .serif).weight(.bold))
                .foregroundStyle(ArkhamTheme.bone)
            if let subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone.opacity(0.7))
            }
        }
        .accessibilityElement(children: .combine)
        .addingHeadingTrait()
    }
}

private extension View {
    /// `.isHeader` is unavailable on tvOS in some toolchains; apply it only where
    /// supported (iOS, macOS, visionOS) so every platform still compiles.
    @ViewBuilder
    func addingHeadingTrait() -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
            accessibilityAddTraits(.isHeader)
        #else
            self
        #endif
    }
}

/// A full-width, prominent primary action button used across every screen for
/// consistency, disabled and progress-aware for in-flight operations, and sized to
/// meet or exceed the platform's minimum interactive target (44pt on touch/pointer
/// platforms per Apple's Human Interface Guidelines; taller on tvOS for ten-foot
/// focus-first readability).
struct ArkhamPrimaryButton: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    /// The minimum height enforced by ``body`` below, satisfying the platform's
    /// minimum touch/click/focus target size.
    private var minimumInteractiveHeight: CGFloat {
        #if os(tvOS)
            64
        #else
            44
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity, minHeight: minimumInteractiveHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(ArkhamTheme.accent)
        .disabled(isLoading)
    }
}

/// A short, non-secret, user-facing failure banner shown beneath a form or action.
struct ArkhamFailureText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A shared banner surfacing a pending cancellation-cleanup failure for a specific
/// profile (see ``AppModel/pendingCleanupFailures``) with an accessible Retry action,
/// used identically wherever that profile can currently be shown to the user (server
/// selection, server management, the signed-in account shell, and the
/// incompatible/unavailable server-issue presentation). Renders nothing when
/// `profileID` currently has no pending cleanup failure.
struct PendingCleanupRetryBanner: View {
    let model: AppModel
    let profileID: UUID

    var body: some View {
        if let failure = model.pendingCleanupFailures[profileID] {
            VStack(alignment: .leading, spacing: 4) {
                ArkhamFailureText(message: failure.message)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.pendingCleanupFailureText(for: profileID)
                    )
                Button("Retry") {
                    Task { await model.retryPendingCleanup(for: profileID) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    AccountAccessibilityID.pendingCleanupRetryButton(for: profileID)
                )
            }
        }
    }
}

extension View {
    /// Applies email-appropriate keyboard/autocapitalization on platforms with an
    /// on-screen keyboard concept, and disables autocorrection everywhere.
    @ViewBuilder
    func emailFieldStyle() -> some View {
        #if os(iOS) || os(visionOS)
            textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }

    /// Applies username-appropriate autocapitalization on platforms with an on-screen
    /// keyboard concept, and disables autocorrection everywhere.
    @ViewBuilder
    func usernameFieldStyle() -> some View {
        #if os(iOS) || os(visionOS)
            textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }

    /// Applies URL-appropriate keyboard/autocapitalization on platforms with an
    /// on-screen keyboard concept, and disables autocorrection everywhere.
    @ViewBuilder
    func urlFieldStyle() -> some View {
        #if os(iOS) || os(visionOS)
            textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }
}
