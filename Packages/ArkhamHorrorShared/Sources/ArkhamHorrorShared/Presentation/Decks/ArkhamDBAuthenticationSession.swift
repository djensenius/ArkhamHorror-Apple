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
    final class ArkhamDBAuthenticationSession: NSObject, ArkhamDBAuthenticating {
        private var session: ASWebAuthenticationSession?
        private var attemptID: UUID?
        private var continuation: CheckedContinuation<URL, any Error>?

        func authenticate(url: URL) async throws -> URL {
            try Task.checkCancellation()
            guard attemptID == nil else { throw ArkhamDBLinkFlowError.failed }
            let attemptID = UUID()
            self.attemptID = attemptID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let session = ASWebAuthenticationSession(
                        url: url, callbackURLScheme: "arkhamhorror"
                    ) { [weak self] url, error in
                        let cancelled = (error as? ASWebAuthenticationSessionError)?
                            .code == .canceledLogin
                        Task { @MainActor in
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
                    session.prefersEphemeralWebBrowserSession = false
                    session.presentationContextProvider = self
                    self.session = session
                    if !session.start() {
                        finish(.failure(ArkhamDBLinkFlowError.failed), attemptID: attemptID)
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    guard self.attemptID == attemptID else { return }
                    self.session?.cancel()
                    self.finish(.failure(CancellationError()), attemptID: attemptID)
                }
            }
        }

        private func finish(_ result: Result<URL, any Error>, attemptID: UUID) {
            guard self.attemptID == attemptID else { return }
            self.attemptID = nil
            let continuation = continuation
            self.continuation = nil
            session = nil
            continuation?.resume(with: result)
        }
    }

    extension ArkhamDBAuthenticationSession: ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
                NSApplication.shared.keyWindow ?? NSApplication.shared.windows
                    .first ?? ASPresentationAnchor()
            #else
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .compactMap(\.keyWindow).first ?? ASPresentationAnchor()
            #endif
        }
    }
#endif
