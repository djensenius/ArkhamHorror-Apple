import Foundation

enum ArkhamDBLinkFlowError: Error, Equatable {
    case invalidAuthorizationURL
    case invalidCallback
    case denied
    case failed
}

extension ArkhamDBLinkStartResponse {
    func authorizationURL() throws -> URL {
        guard let url = URL(string: authorizeUrl), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else {
            throw ArkhamDBLinkFlowError.invalidAuthorizationURL
        }
        return url
    }
}

extension ArkhamDBLinkCompletionRequest {
    init(callback: URL) throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "arkhamhorror", components.host == "arkhamdb-link",
              components.path.isEmpty, components.fragment == nil
        else {
            throw ArkhamDBLinkFlowError.invalidCallback
        }
        let items = components.queryItems ?? []
        let results = items.filter { $0.name == "result" }
        guard results.count == 1 else { throw ArkhamDBLinkFlowError.invalidCallback }
        if results.first?.value == "error" {
            throw items.first(where: { $0.name == "reason" })?.value == "access_denied"
                ? ArkhamDBLinkFlowError.denied : ArkhamDBLinkFlowError.failed
        }
        let secrets = items.filter { $0.name == "completion" }
        guard results.first?.value == "pending", secrets.count == 1,
              let raw = secrets.first?.value, !raw.isEmpty
        else {
            throw ArkhamDBLinkFlowError.invalidCallback
        }
        completion = try ArkhamDBCompletionSecret(raw)
    }
}
