@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Production assignment replay Git identity")
struct AssignmentReplayGitIdentityTests {
    @Test("Repository and config environment overrides cannot spoof the revision")
    func gitEnvironmentOverridesAreIgnored() throws {
        let fixture = try makeGitSpoofFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.scratchDirectory)
        }
        for environment in gitSpoofOverrides(fixture) {
            #expect(
                try ProductionAssignmentReplayGitRevision.current(
                    startingAt: fixture.nested,
                    inheritedEnvironment: environment
                ) == fixture.trustedRevision
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.fsmonitorSentinel.path
        ))
    }

    @Test("Linked worktrees resolve their administrative Git directory")
    func linkedWorktreeGitfileIsSupported() throws {
        let scratch = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
        let source = scratch.directory.appendingPathComponent(
            "source",
            isDirectory: true
        )
        let linked = scratch.directory.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        let revision = try makeGitRepository(
            at: source,
            contents: "trusted"
        )
        _ = try runTestGit(
            ["worktree", "add", "--quiet", "--detach", linked.path, revision],
            in: source
        )
        defer {
            _ = try? runTestGit(
                ["worktree", "remove", "--force", linked.path],
                in: source
            )
        }
        let nested = linked.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )

        #expect(
            try ProductionAssignmentReplayGitRevision.current(
                startingAt: nested
            ) == revision
        )
    }
}

private struct GitSpoofFixture {
    let scratchDirectory: URL
    let trusted: URL
    let nested: URL
    let attacker: URL
    let maliciousConfig: URL
    let fsmonitorSentinel: URL
    let trustedRevision: String
}

private func makeGitSpoofFixture() throws -> GitSpoofFixture {
    let scratch = try makeScratch()
    let trusted = scratch.directory.appendingPathComponent(
        "trusted",
        isDirectory: true
    )
    let attacker = scratch.directory.appendingPathComponent(
        "attacker",
        isDirectory: true
    )
    let trustedRevision = try makeGitRepository(
        at: trusted,
        contents: "trusted"
    )
    try installReplacementRef(
        in: trusted,
        replacing: trustedRevision
    )
    _ = try makeGitRepository(at: attacker, contents: "attacker")
    let nested = trusted.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: false
    )
    let maliciousConfig = scratch.directory.appendingPathComponent(
        "malicious.gitconfig"
    )
    try Data(
        "[core]\n\tworktree = \(attacker.path)\n".utf8
    ).write(to: maliciousConfig)
    let sentinel = scratch.directory.appendingPathComponent("fsmonitor-ran")
    let fsmonitor = scratch.directory.appendingPathComponent("fsmonitor")
    try installRepositoryConfigSpoofs(
        in: trusted,
        worktree: attacker,
        fsmonitor: fsmonitor,
        sentinel: sentinel
    )
    return GitSpoofFixture(
        scratchDirectory: scratch.directory,
        trusted: trusted,
        nested: nested,
        attacker: attacker,
        maliciousConfig: maliciousConfig,
        fsmonitorSentinel: sentinel,
        trustedRevision: trustedRevision
    )
}

private func installReplacementRef(
    in trusted: URL,
    replacing trustedRevision: String
) throws {
    try Data("replacement".utf8).write(
        to: trusted.appendingPathComponent("tracked.txt")
    )
    _ = try runTestGit(["add", "tracked.txt"], in: trusted)
    _ = try runTestGit(
        [
            "-c", "user.name=Replay Test",
            "-c", "user.email=replay@example.invalid",
            "commit", "--quiet", "-m", "replacement",
        ],
        in: trusted
    )
    let replacementRevision = try runTestGit(
        ["rev-parse", "HEAD"],
        in: trusted
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try runTestGit(
        ["checkout", "--quiet", "--detach", trustedRevision],
        in: trusted
    )
    _ = try runTestGit(
        ["replace", trustedRevision, replacementRevision],
        in: trusted
    )
    let replacementStatus = try runTestGit(
        ["status", "--porcelain=v1", "--untracked-files=all"],
        in: trusted
    )
    guard !replacementStatus.isEmpty else {
        throw ProductionAssignmentReplayError.appleRevisionUnavailable
    }
}

private func installRepositoryConfigSpoofs(
    in trusted: URL,
    worktree: URL,
    fsmonitor: URL,
    sentinel: URL
) throws {
    try Data("#!/bin/sh\n: > '\(sentinel.path)'\n".utf8).write(to: fsmonitor)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fsmonitor.path
    )
    _ = try runTestGit(
        ["config", "core.fsmonitor", fsmonitor.path],
        in: trusted
    )
    _ = try runTestGit(
        ["config", "core.worktree", worktree.path],
        in: trusted
    )
}

private func gitSpoofOverrides(
    _ fixture: GitSpoofFixture
) -> [[String: String]] {
    let attackerGit = fixture.attacker.appendingPathComponent(".git").path
    return [
        ["GIT_NO_REPLACE_OBJECTS": "0"],
        ["GIT_DIR": attackerGit],
        ["GIT_WORK_TREE": fixture.attacker.path],
        [
            "GIT_DIR": attackerGit,
            "GIT_WORK_TREE": fixture.attacker.path,
        ],
        [
            "GIT_CONFIG_GLOBAL": fixture.maliciousConfig.path,
            "HOME": fixture.attacker.path,
            "XDG_CONFIG_HOME": fixture.attacker.path,
        ],
        [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.worktree",
            "GIT_CONFIG_VALUE_0": fixture.attacker.path,
        ],
        [
            "GIT_CONFIG_PARAMETERS":
                "'core.worktree=\(fixture.attacker.path)'",
        ],
        [
            "GIT_COMMON_DIR": attackerGit,
            "GIT_OBJECT_DIRECTORY": "\(attackerGit)/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": "\(attackerGit)/objects",
            "GIT_INDEX_FILE": "\(attackerGit)/index",
        ],
        [
            "GIT_CEILING_DIRECTORIES": fixture.trusted.path,
            "GIT_CONFIG_SYSTEM": fixture.maliciousConfig.path,
            "GIT_ATTR_NOSYSTEM": "0",
            "GIT_EXEC_PATH": fixture.attacker.path,
        ],
    ]
}

private func makeGitRepository(
    at directory: URL,
    contents: String
) throws -> String {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    _ = try runTestGit(["init", "--quiet"], in: directory)
    try Data(contents.utf8).write(
        to: directory.appendingPathComponent("tracked.txt")
    )
    _ = try runTestGit(["add", "tracked.txt"], in: directory)
    _ = try runTestGit(
        [
            "-c", "user.name=Replay Test",
            "-c", "user.email=replay@example.invalid",
            "commit", "--quiet", "-m", "fixture",
        ],
        in: directory
    )
    return try runTestGit(["rev-parse", "HEAD"], in: directory)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func runTestGit(
    _ arguments: [String],
    in directory: URL
) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit,
          process.terminationStatus == 0,
          let value = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )
    else {
        throw ProductionAssignmentReplayError.appleRevisionUnavailable
    }
    return value
}
