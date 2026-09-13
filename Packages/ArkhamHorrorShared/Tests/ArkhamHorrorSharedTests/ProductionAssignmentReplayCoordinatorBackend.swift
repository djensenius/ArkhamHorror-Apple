@testable import ArkhamHorrorShared
import Foundation

protocol AssignmentReplayCoordinatorBackend: Sendable {
    func importCheckpoint(
        _ checkpoint: AssignmentReplayCheckpointFile,
        investigatorID: InvestigatorID,
        profile: ServerProfile,
        token: String,
        deadline: AssignmentReplayCoordinatorDeadline
    ) async throws -> GameID

    func getGame(
        _ gameID: GameID,
        profile: ServerProfile,
        token: String,
        deadline: AssignmentReplayCoordinatorDeadline
    ) async throws -> GetGameEnvelope

    func fetchAttestation(
        _ request: AssignmentReplayAttestationRequest,
        deadline: AssignmentReplayCoordinatorDeadline
    ) async throws -> ProductionAssignmentReplayAttestation
}

struct ProductionAssignmentReplayBackend: AssignmentReplayCoordinatorBackend {
    static let maximumImportResponseBytes = 64 * 1024 * 1024
    static let maximumGameResponseBytes = 64 * 1024 * 1024

    func importCheckpoint(
        _ checkpoint: AssignmentReplayCheckpointFile,
        investigatorID: InvestigatorID,
        profile: ServerProfile,
        token: String,
        deadline: AssignmentReplayCoordinatorDeadline
    ) async throws -> GameID {
        let url = Self.importURL(profile: profile)
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
            deadline: deadline,
            failure: .importFailed
        )
        return try Self.decodeImportedGameID(from: response)
    }

    func getGame(
        _ gameID: GameID,
        profile: ServerProfile,
        token: String,
        deadline: AssignmentReplayCoordinatorDeadline
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
            deadline: deadline,
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
        _ request: AssignmentReplayAttestationRequest,
        deadline: AssignmentReplayCoordinatorDeadline
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
        deadline: AssignmentReplayCoordinatorDeadline,
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

    static func importURL(profile: ServerProfile) -> URL {
        profile.endpointURL(
            path: "/arkham/games/import",
            pin: .current
        )
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

    static func decodeImportedGameID(
        from response: Data,
        maxByteCount: Int = maximumImportResponseBytes
    ) throws -> GameID {
        do {
            let game = try ContractJSON.decode(
                PublicGameSnapshot.self,
                from: response,
                maxByteCount: maxByteCount
            )
            let original = try LosslessJSONParser.parse(response)
            let reencoded = try LosslessJSONParser.parse(
                ContractJSON.encode(game)
            )
            guard original == reencoded else {
                throw ProductionAssignmentReplayCoordinatorError
                    .importedGameMalformed
            }
            return game.id
        } catch {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
