import Foundation

@MainActor
protocol ArkhamDBAuthenticating: AnyObject {
    func authenticate(url: URL) async throws -> URL
}

#if !os(tvOS)
    import AuthenticationServices
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    @MainActor
    protocol ArkhamDBNativeAuthenticationSession: AnyObject {
        func start() -> Bool
        func cancel()
    }

    extension ASWebAuthenticationSession: ArkhamDBNativeAuthenticationSession {}

    @MainActor
    final class ArkhamDBAuthenticationSession: NSObject, ArkhamDBAuthenticating {
        typealias Factory = @MainActor (
            URL,
            any ASWebAuthenticationPresentationContextProviding,
            @escaping @Sendable (URL?, (any Error)?) -> Void
        ) -> any ArkhamDBNativeAuthenticationSession

        private let factory: Factory
        private weak var anchor: ASPresentationAnchor?
        private var context: ArkhamDBAuthenticationContext?
        private var session: (any ArkhamDBNativeAuthenticationSession)?
        private var attemptID: UUID?
        private var continuation: CheckedContinuation<URL, any Error>?

        init(factory: @escaping Factory = ArkhamDBAuthenticationSession.makeSession) {
            self.factory = factory
        }

        /// Only the window containing the presenting sheet may authorize a browser.
        /// Detaching or moving that sheet invalidates the in-flight attempt.
        func updatePresentationAnchor(_ anchor: ASPresentationAnchor?) {
            guard self.anchor !== anchor else { return }
            self.anchor = anchor
            if let attemptID {
                finish(
                    .failure(ArkhamDBLinkFlowError.presentationUnavailable),
                    attemptID: attemptID, cancelSession: true
                )
            }
        }

        func authenticate(url: URL) async throws -> URL {
            try Task.checkCancellation()
            guard attemptID == nil else { throw ArkhamDBLinkFlowError.failed }
            guard let anchor, Self.canPresent(from: anchor) else {
                throw ArkhamDBLinkFlowError.presentationUnavailable
            }
            let context = ArkhamDBAuthenticationContext(anchor: anchor)
            self.context = context
            let attemptID = UUID()
            self.attemptID = attemptID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let session = factory(url, context) { [weak self] url, error in
                        let cancelled = (error as? ASWebAuthenticationSessionError)?
                            .code == .canceledLogin
                        Task { @MainActor [weak self] in
                            if let url {
                                self?.finish(.success(url), attemptID: attemptID)
                            } else if cancelled {
                                self?.finish(.failure(CancellationError()), attemptID: attemptID)
                            } else {
                                self?.finish(
                                    .failure(ArkhamDBLinkFlowError.failed),
                                    attemptID: attemptID
                                )
                            }
                        }
                    }
                    self.session = session
                    if !session.start() {
                        finish(
                            .failure(ArkhamDBLinkFlowError.failed),
                            attemptID: attemptID, cancelSession: true
                        )
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    guard self.attemptID == attemptID else { return }
                    self.finish(
                        .failure(CancellationError()),
                        attemptID: attemptID, cancelSession: true
                    )
                }
            }
        }

        private func finish(
            _ result: Result<URL, any Error>, attemptID: UUID, cancelSession: Bool = false
        ) {
            guard self.attemptID == attemptID else { return }
            self.attemptID = nil
            let continuation = continuation
            self.continuation = nil
            let session = session
            self.session = nil
            context = nil
            if cancelSession {
                session?.cancel()
            }
            continuation?.resume(with: result)
        }

        private static func canPresent(from anchor: ASPresentationAnchor) -> Bool {
            #if os(macOS)
                anchor.isVisible
            #else
                !anchor.isHidden && anchor.windowScene.map {
                    $0.activationState == .foregroundActive
                        || $0.activationState == .foregroundInactive
                } == true
            #endif
        }

        private static func makeSession(
            url: URL,
            context: any ASWebAuthenticationPresentationContextProviding,
            completion: @escaping @Sendable (URL?, (any Error)?) -> Void
        ) -> any ArkhamDBNativeAuthenticationSession {
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "arkhamhorror", completionHandler: completion
            )
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = context
            return session
        }
    }

    /// A valid anchor is captured before start and retained only for that attempt.
    /// The native provider cannot return nil; it never invents a fallback window.
    @MainActor
    private final class ArkhamDBAuthenticationContext: NSObject {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }
    }

    extension ArkhamDBAuthenticationContext: ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor
        }
    }
#endif
