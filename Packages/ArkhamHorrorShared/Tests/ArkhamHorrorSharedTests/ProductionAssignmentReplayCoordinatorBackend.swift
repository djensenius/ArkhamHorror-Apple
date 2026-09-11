@testable import ArkhamHorrorShared
import Foundation

protocol AssignmentReplayCoordinatorBackend: Sendable {
    func importCheckpoint(
        _ checkpoint: AssignmentReplayCheckpointFile,
        investigatorID: InvestigatorID,
        profile: ServerProfile,
        token: String
    ) async throws -> GameID

    func getGame(
        _ gameID: GameID,
        profile: ServerProfile,
        token: String
    ) async throws -> GetGameEnvelope

    func fetchAttestation(
        _ request: AssignmentReplayAttestationRequest
    ) async throws -> ProductionAssignmentReplayAttestation
}

struct ProductionAssignmentReplayBackend: AssignmentReplayCoordinatorBackend {
    private static let maximumImportResponseBytes = 64 * 1024
    private static let maximumGameResponseBytes = 64 * 1024 * 1024

    let deadline: AssignmentReplayCoordinatorDeadline

    func importCheckpoint(
        _ checkpoint: AssignmentReplayCheckpointFile,
        investigatorID: InvestigatorID,
        profile: ServerProfile,
        token: String
    ) async throws -> GameID {
        let url = try importURL(profile: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Token \(token)",
            forHTTPHeaderField: "Authorization"
        )
        let boundary = "ArkhamReplay-\(UUID().uuidString.lowercased())"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(
            checkpoint: checkpoint.bytes,
            investigatorID: investigatorID,
            boundary: boundary
        )

        let response = try await fetch(
            request,
            expectedURL: url,
            maxByteCount: Self.maximumImportResponseBytes,
            failure: .importFailed
        )
        do {
            let value = try ContractJSON.decode(
                JSONValue.self,
                from: response,
                maxByteCount: Self.maximumImportResponseBytes
            )
            guard case let .object(root) = value,
                  Set(root.keys) == ["id"]
            else {
                throw ProductionAssignmentReplayCoordinatorError
                    .importedGameMalformed
            }
            return try ContractJSON.decode(
                ImportedGameIdentity.self,
                from: response,
                maxByteCount: Self.maximumImportResponseBytes
            ).id
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        }
    }

    func getGame(
        _ gameID: GameID,
        profile: ServerProfile,
        token: String
    ) async throws -> GetGameEnvelope {
        let url: URL
        do {
            url = try GameLifecycleService.gameURL(
                gameID,
                on: profile,
                pin: .current
            )
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .authoritativeGameMalformed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Token \(token)",
            forHTTPHeaderField: "Authorization"
        )
        let response = try await fetch(
            request,
            expectedURL: url,
            maxByteCount: Self.maximumGameResponseBytes,
            failure: .authoritativeGameMalformed
        )
        do {
            return try ContractJSON.decode(
                GetGameEnvelope.self,
                from: response,
                maxByteCount: Self.maximumGameResponseBytes
            )
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .authoritativeGameMalformed
        }
    }

    func fetchAttestation(
        _ request: AssignmentReplayAttestationRequest
    ) async throws -> ProductionAssignmentReplayAttestation {
        let transport = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount:
            AssignmentReplayAttestationClient.maximumResponseBytes,
            deadline: deadline
        )
        return try await AssignmentReplayAttestationClient(
            transport: transport
        ).fetch(request: request)
    }

    private func fetch(
        _ request: URLRequest,
        expectedURL: URL,
        maxByteCount: Int,
        failure: ProductionAssignmentReplayCoordinatorError
    ) async throws -> Data {
        let transport = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: maxByteCount,
            deadline: deadline
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw failure
        }
        guard let http = response as? HTTPURLResponse,
              http.url == expectedURL,
              (200 ... 299).contains(http.statusCode),
              Self.isJSONContentType(
                  http.value(forHTTPHeaderField: "Content-Type")
              )
        else {
            throw failure
        }
        return data
    }

    private func importURL(profile: ServerProfile) throws -> URL {
        let base = profile.endpointURL(
            path: "/arkham/games/import",
            pin: .current
        )
        guard var components = URLComponents(
            url: base,
            resolvingAgainstBaseURL: false
        ) else {
            throw ProductionAssignmentReplayCoordinatorError.importFailed
        }
        components.queryItems = [
            URLQueryItem(
                name: "multiplayerVariant",
                value: RequestMultiplayerVariant.withFriends.rawValue
            ),
        ]
        guard let url = components.url else {
            throw ProductionAssignmentReplayCoordinatorError.importFailed
        }
        return url
    }

    private func multipartBody(
        checkpoint: Data,
        investigatorID: InvestigatorID,
        boundary: String
    ) -> Data {
        var body = Data()
        body.appendASCII("--\(boundary)\r\n")
        body.appendASCII(
            "Content-Disposition: form-data; name=\"debugFile\"; " +
                "filename=\"assignment.checkpoint.json\"\r\n"
        )
        body.appendASCII("Content-Type: application/json\r\n\r\n")
        body.append(checkpoint)
        body.appendASCII("\r\n--\(boundary)\r\n")
        body.appendASCII(
            "Content-Disposition: form-data; name=\"investigatorId\"\r\n\r\n"
        )
        body.appendASCII(investigatorID.codingKey.stringValue)
        body.appendASCII("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func isJSONContentType(_ rawValue: String?) -> Bool {
        guard let rawValue,
              rawValue.utf8.allSatisfy({ $0 < 0x80 })
        else {
            return false
        }
        let mediaType = rawValue
            .split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return mediaType == "application/json"
    }
}

private struct ImportedGameIdentity: Decodable {
    let id: GameID
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
