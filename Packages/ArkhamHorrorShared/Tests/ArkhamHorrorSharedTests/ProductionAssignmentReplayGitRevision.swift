import Darwin
import Foundation

enum ProductionAssignmentReplayGitRevision {
    static func current(
        startingAt startURL: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let trustedStart: URL
        if let startURL {
            trustedStart = startURL
        } else {
            guard #filePath.hasPrefix("/") else {
                throw ProductionAssignmentReplayError.appleRevisionUnavailable
            }
            trustedStart = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
        }
        let root = try repositoryRoot(startingAt: trustedStart)
        let topLevelData = try runGit(
            ["rev-parse", "--show-toplevel"],
            in: root,
            inheritedEnvironment: inheritedEnvironment
        )
        guard let topLevelPath = String(data: topLevelData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            canonicalDirectory(URL(fileURLWithPath: topLevelPath)) == root
        else {
            throw ProductionAssignmentReplayError.appleRevisionUnavailable
        }
        let revisionData = try runGit(
            ["rev-parse", "HEAD"],
            in: root,
            inheritedEnvironment: inheritedEnvironment
        )
        guard let raw = String(data: revisionData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            isLowercaseGitRevision(raw)
        else {
            throw ProductionAssignmentReplayError.appleRevisionUnavailable
        }
        let status = try runGit(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            in: root,
            inheritedEnvironment: inheritedEnvironment
        )
        guard status.isEmpty else {
            throw ProductionAssignmentReplayError.appleSourceDirty
        }
        return raw
    }

    private static func runGit(
        _ arguments: [String],
        in root: URL,
        inheritedEnvironment: [String: String]
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-pager",
            "--git-dir=\(root.appendingPathComponent(".git").path)",
            "--work-tree=\(root.path)",
            "-c", "core.attributesFile=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.untrackedCache=false",
            "-c", "diff.external=",
            "-c", "status.showUntrackedFiles=all",
            "-c", "status.submoduleSummary=false",
        ] + arguments
        process.currentDirectoryURL = root
        process.environment = sanitizedEnvironment(inheritedEnvironment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProductionAssignmentReplayError.appleRevisionUnavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProductionAssignmentReplayError.appleRevisionUnavailable
        }
        return data
    }

    private static func repositoryRoot(startingAt startURL: URL) throws -> URL {
        var candidate = canonicalDirectory(startURL)
        while true {
            if isOwnedRepositoryMarker(
                candidate.appendingPathComponent(".git")
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw ProductionAssignmentReplayError.appleRevisionUnavailable
            }
            candidate = parent
        }
    }

    private static func sanitizedEnvironment(
        _: [String: String]
    ) -> [String: String] {
        [
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "HOME": "/nonexistent",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": "/nonexistent",
        ]
    }

    private static func canonicalDirectory(_ url: URL) -> URL {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func isOwnedRepositoryMarker(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return false
        }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFDIR || kind == S_IFREG
    }

    private static func isLowercaseGitRevision(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
            }
    }
}
