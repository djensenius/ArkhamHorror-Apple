@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

@Suite("SecureCacheDirectory missing-anchor fallback")
struct SecureCacheDirectoryAnchorFallbackTests {
    private func withScratchDirectory(_ body: (URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheAnchorFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, home.appendingPathComponent("Library/Caches", isDirectory: true))
    }

    private func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(fcntl(descriptor, F_GETPATH, &buffer) == 0)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    @Test("Missing Caches is created and verified below the containing home anchor")
    func createsMissingCachesBelowHome() throws {
        try withScratchDirectory { home, caches in
            let target = caches.appendingPathComponent("Assets/v1", isDirectory: true)
            var inspected: [String] = []
            let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                at: target, trustAnchors: [caches, home],
                directoryStat: { descriptor, info in
                    inspected.append(URL(fileURLWithPath: path(of: descriptor)).lastPathComponent)
                    return fstat(descriptor, &info)
                }
            )
            defer { close(result.descriptor) }
            #expect(inspected == [home.lastPathComponent, "Library", "Caches", "Assets", "v1"])
            #expect(result.leafWasFreshlyCreated)
            #expect(FileManager.default.fileExists(atPath: target.path))
            var info = stat()
            #expect(fstat(result.descriptor, &info) == 0)
            #expect(info.st_uid == getuid())
            #expect(info.st_mode & S_IWOTH == 0)
        }
    }

    @Test("Symlinked Caches fails without opening the broader home anchor")
    func symlinkAnchorNeverFallsBack() throws {
        try withScratchDirectory { home, caches in
            try FileManager.default.createDirectory(
                at: caches.deletingLastPathComponent(), withIntermediateDirectories: false
            )
            let outside = home.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: outside)
            var statCalls = 0
            #expect(throws: AssetError.self) {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: caches.appendingPathComponent("Assets/v1"), trustAnchors: [caches, home],
                    directoryStat: { descriptor, info in
                        statCalls += 1
                        return fstat(descriptor, &info)
                    }
                )
                close(result.descriptor)
            }
            #expect(statCalls == 0)
            #expect(!FileManager.default
                .fileExists(atPath: outside.appendingPathComponent("Assets").path))
        }
    }

    @Test("A wrong-owner Caches descriptor fails without retrying from home")
    func untrustedAnchorNeverFallsBack() throws {
        try withScratchDirectory { home, caches in
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            var inspected: [String] = []
            #expect(throws: AssetError.cachePersistenceFailed(
                "Path component '\(caches.path)' has an untrusted owner"
            )) {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: caches.appendingPathComponent("Assets/v1"), trustAnchors: [caches, home],
                    directoryStat: { descriptor, info in
                        inspected
                            .append(URL(fileURLWithPath: path(of: descriptor)).lastPathComponent)
                        let status = fstat(descriptor, &info)
                        // Simulate a foreign owner on the first descriptor
                        // only: retrying under home must not hide this failure.
                        if inspected.count == 1 {
                            info.st_uid = getuid() + 12345
                        }
                        return status
                    }
                )
                close(result.descriptor)
            }
            #expect(inspected == ["Caches"])
            #expect(!FileManager.default
                .fileExists(atPath: caches.appendingPathComponent("Assets").path))
        }
    }
}
