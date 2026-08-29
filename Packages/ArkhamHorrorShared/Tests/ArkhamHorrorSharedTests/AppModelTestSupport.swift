@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Test doubles shared by AppModel test files

struct TestFailure: Error, Sendable {}

struct SensitiveTestFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

/// An in-memory ``ServerProfileStore`` whose reads and writes can be scripted to throw,
/// so startup storage handling can be exercised deterministically.
final class FakeServerProfileStore: ServerProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [ServerProfile]
    private var selectedID: UUID?
    private var loadProfilesError: (any Error)?
    private var loadSelectionError: (any Error)?
    private var saveProfilesError: (any Error)?
    private var saveSelectionError: (any Error)?
    private(set) var saveProfilesCallCount = 0
    private(set) var saveSelectionCallCount = 0

    init(
        profiles: [ServerProfile] = [],
        selectedID: UUID? = nil,
        loadProfilesError: (any Error)? = nil,
        loadSelectionError: (any Error)? = nil,
        saveProfilesError: (any Error)? = nil,
        saveSelectionError: (any Error)? = nil
    ) {
        self.profiles = profiles
        self.selectedID = selectedID
        self.loadProfilesError = loadProfilesError
        self.loadSelectionError = loadSelectionError
        self.saveProfilesError = saveProfilesError
        self.saveSelectionError = saveSelectionError
    }

    func loadProfiles() throws -> [ServerProfile] {
        lock.lock()
        defer { lock.unlock() }
        if let loadProfilesError {
            throw loadProfilesError
        }
        return profiles
    }

    func saveProfiles(_ profiles: [ServerProfile]) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveProfilesError {
            throw saveProfilesError
        }
        saveProfilesCallCount += 1
        self.profiles = profiles
    }

    func loadSelectedProfileID() throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if let loadSelectionError {
            throw loadSelectionError
        }
        return selectedID
    }

    func saveSelectedProfileID(_ id: UUID?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveSelectionError {
            throw saveSelectionError
        }
        saveSelectionCallCount += 1
        selectedID = id
    }

    func snapshotProfiles() -> [ServerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    func snapshotSelectedID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return selectedID
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``loadProfiles()`` call.
    func setLoadProfilesError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        loadProfilesError = error
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``saveProfiles(_:)`` call.
    func setSaveProfilesError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        saveProfilesError = error
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``saveSelectedProfileID(_:)`` call.
    func setSaveSelectionError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        saveSelectionError = error
    }
}

/// An in-memory ``TokenStore`` whose operations can be scripted to throw, with call
/// counts so tests can assert whether a token was retained, saved, or deleted.
actor FakeTokenStore: TokenStore {
    private var tokens: [UUID: String]
    private var readError: (any Error)?
    private var saveError: (any Error)?
    private var deleteError: (any Error)?
    private var deleteAllError: (any Error)?
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deleteAllCallCount = 0
    private(set) var lastSavedToken: String?

    init(tokens: [UUID: String] = [:]) {
        self.tokens = tokens
    }

    func setReadError(_ error: (any Error)?) {
        readError = error
    }

    func setSaveError(_ error: (any Error)?) {
        saveError = error
    }

    func setDeleteError(_ error: (any Error)?) {
        deleteError = error
    }

    func setDeleteAllError(_ error: (any Error)?) {
        deleteAllError = error
    }

    func snapshotTokens() -> [UUID: String] {
        tokens
    }

    func token(for profileID: UUID) async throws -> String? {
        if let readError {
            throw readError
        }
        return tokens[profileID]
    }

    func save(_ token: String, for profileID: UUID) async throws {
        if let saveError {
            throw saveError
        }
        saveCallCount += 1
        lastSavedToken = token
        tokens[profileID] = token
    }

    func deleteToken(for profileID: UUID) async throws {
        if let deleteError {
            throw deleteError
        }
        deleteCallCount += 1
        tokens[profileID] = nil
    }

    func deleteAllTokens() async throws {
        if let deleteAllError {
            throw deleteAllError
        }
        deleteAllCallCount += 1
        tokens.removeAll()
    }
}

// MARK: - Fixtures

extension CurrentUser {
    static let sample = CurrentUser(
        username: "ashcan",
        email: "ashcan@example.com",
        beta: false,
        admin: false
    )
}

/// A valid custom (self-hosted) profile fixture. Constructed via a closure rather than
/// `try!` so a malformed literal fails loudly with a clear message instead of tripping a
/// force-try lint violation.
let sampleCustomProfile: ServerProfile = {
    do {
        return try ServerProfile.custom(
            displayName: "Self-hosted",
            rawURL: "https://self-hosted.example.com"
        )
    } catch {
        fatalError("sampleCustomProfile fixture must be a valid custom profile: \(error)")
    }
}()
