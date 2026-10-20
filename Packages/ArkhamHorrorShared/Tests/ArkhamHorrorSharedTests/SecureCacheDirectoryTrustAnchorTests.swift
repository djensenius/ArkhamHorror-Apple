@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

@Suite("SecureCacheDirectory container trust anchor")
struct SecureCacheDirectoryTrustAnchorTests {
    private func withScratchDirectory(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheTrustAnchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    /// Observes the actual descriptor passed to the production fstat seam,
    /// rather than trusting a separate trace of intended path strings.
    private func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(fcntl(descriptor, F_GETPATH, &buffer) == 0)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func physicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(realpath(url.path, &buffer) != nil)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    @Test("fstat starts at the anchor and never inspects its world-writable parent")
    func walkNeverInspectsAboveAnchor() throws {
        try withScratchDirectory { base in
            let anchor = base.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
            #expect(chmod(base.path, 0o777) == 0)
            defer { _ = chmod(base.path, 0o700) }
            let nested = anchor.appendingPathComponent("nested", isDirectory: true)
            let target = nested.appendingPathComponent("cache", isDirectory: true)
            var inspected: [String] = []
            let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                at: target, trustAnchor: anchor,
                directoryStat: { descriptor, info in
                    inspected.append(path(of: descriptor))
                    return fstat(descriptor, &info)
                }
            )
            defer { close(result.descriptor) }
            #expect(inspected == [physicalPath(anchor), physicalPath(nested), physicalPath(target)])
            #expect(result.leafWasFreshlyCreated)
            let reopened = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                at: target, trustAnchor: anchor
            )
            defer { close(reopened.descriptor) }
            #expect(!reopened.leafWasFreshlyCreated)
        }
    }

    @Test("Production selection uses FileManager Caches, not home or the filesystem root")
    func productionWalkStartsAtCaches() throws {
        let fileManager = FileManager.default
        let caches = try #require(fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first)
        let target = caches.appendingPathComponent("CacheTrustAnchor-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: target) }
        var inspected: [String] = []
        let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
            at: target, fileManager: fileManager,
            directoryStat: { descriptor, info in
                inspected.append(path(of: descriptor))
                return fstat(descriptor, &info)
            }
        )
        defer { close(result.descriptor) }
        #expect(inspected == [physicalPath(caches), physicalPath(target)])
    }

    @Test("Home and temporary fallback anchors come from FileManager for development runs")
    func developmentAnchorsComeFromFileManager() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let homeTarget = home.appendingPathComponent("CacheTrustAnchor-\(UUID().uuidString)")
        let temp = fileManager.temporaryDirectory
        let tempTarget = temp.appendingPathComponent("CacheTrustAnchor-\(UUID().uuidString)")
        #expect(try SecureCacheDirectory.cacheTrustAnchor(
            for: homeTarget,
            fileManager: fileManager
        ) == home)
        #expect(try SecureCacheDirectory.cacheTrustAnchor(
            for: tempTarget,
            fileManager: fileManager
        ) == temp)
    }

    @Test("Containment accepts iOS-family, sandboxed macOS, and unsandboxed macOS Caches spellings")
    func platformCacheSpellings() throws {
        let anchors = [
            "/var/mobile/Containers/Data/Application/example/Library/Caches",
            "/Users/example/Library/Containers/org.example.Arkham/Data/Library/Caches",
            "/Users/example/Library/Caches",
        ]
        for anchor in anchors {
            let directory = anchor.replacingOccurrences(of: "/var/", with: "/private/var/")
                + "/ArkhamHorrorAssets/v1"
            let relative = try SecureCacheDirectory.cacheRelativeComponents(
                of: URL(fileURLWithPath: directory), below: URL(fileURLWithPath: anchor)
            )
            #expect(relative == ["ArkhamHorrorAssets", "v1"])
        }
    }

    @Test("Equal, sibling-prefix, and dot-dot escape paths fail before any metadata access")
    func rejectsPathsNotStrictlyBelowAnchor() throws {
        try withScratchDirectory { base in
            let anchor = base.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
            let paths = [
                anchor,
                base.appendingPathComponent("container-sibling/cache"),
                anchor.appendingPathComponent("../escaped/cache"),
            ]
            for target in paths {
                var statCalls = 0
                #expect(throws: AssetError.self) {
                    let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                        at: target, trustAnchor: anchor,
                        directoryStat: { descriptor, info in
                            statCalls += 1
                            return fstat(descriptor, &info)
                        }
                    )
                    close(result.descriptor)
                }
                #expect(statCalls == 0)
            }
        }
    }

    @Test("Production selection rejects locations outside all FileManager anchors")
    func rejectsOutsideFileManagerAnchors() {
        let outside = URL(fileURLWithPath: "/Volumes/OutsideAppContainer/cache")
        #expect(throws: AssetError.self) {
            _ = try SecureCacheDirectory.cacheTrustAnchor(for: outside, fileManager: .default)
        }
    }

    @Test("A planted symlink inside the anchored walk never redirects cache creation")
    func rejectsSymlinkBelowAnchor() throws {
        try withScratchDirectory { anchor in
            let outside = anchor.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let link = anchor.appendingPathComponent("planted")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(throws: AssetError.self) {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: link.appendingPathComponent("cache"), trustAnchor: anchor
                )
                close(result.descriptor)
            }
            #expect(!FileManager.default
                .fileExists(atPath: outside.appendingPathComponent("cache").path))
        }
    }

    @Test("The anchor itself cannot be a symlink")
    func rejectsSymlinkAnchor() throws {
        try withScratchDirectory { base in
            let real = base.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            let link = base.appendingPathComponent("anchor")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            #expect(throws: AssetError.self) {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: link.appendingPathComponent("cache"), trustAnchor: link
                )
                close(result.descriptor)
            }
            #expect(!FileManager.default
                .fileExists(atPath: real.appendingPathComponent("cache").path))
        }
    }

    @Test("An untrusted owner inside the walk fails even though the anchor is trusted")
    func rejectsUntrustedOwnerBelowAnchor() throws {
        try withScratchDirectory { anchor in
            let component = anchor.appendingPathComponent("untrusted", isDirectory: true)
            var inspected: [String] = []
            #expect(throws: AssetError
                .cachePersistenceFailed("Path component 'untrusted' has an untrusted owner"))
            {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: component.appendingPathComponent("cache"), trustAnchor: anchor,
                    directoryStat: { descriptor, info in
                        let inspectedPath = path(of: descriptor)
                        inspected.append(inspectedPath)
                        let status = fstat(descriptor, &info)
                        // Simulate chown without root privileges, after the
                        // same real descriptor-based stat production uses.
                        if inspectedPath.hasSuffix("/untrusted") {
                            info.st_uid = getuid() + 12345
                        }
                        return status
                    }
                )
                close(result.descriptor)
            }
            #expect(inspected == [physicalPath(anchor), physicalPath(component)])
            #expect(!FileManager.default
                .fileExists(atPath: component.appendingPathComponent("cache").path))
        }
    }

    @Test("A world-writable component inside the walk fails even with a trusted owner")
    func rejectsWorldWritableComponentBelowAnchor() throws {
        try withScratchDirectory { anchor in
            let component = anchor.appendingPathComponent("writable", isDirectory: true)
            try FileManager.default.createDirectory(
                at: component,
                withIntermediateDirectories: false
            )
            #expect(chmod(component.path, 0o777) == 0)
            #expect(throws: AssetError
                .cachePersistenceFailed("Path component 'writable' is world-writable"))
            {
                let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                    at: component.appendingPathComponent("cache"), trustAnchor: anchor
                )
                close(result.descriptor)
            }
            #expect(!FileManager.default
                .fileExists(atPath: component.appendingPathComponent("cache").path))
        }
    }

    @Test("Replacing the anchor path after opening it cannot redirect the openat walk")
    func anchorReplacementDoesNotRedirectWalk() throws {
        try withScratchDirectory { base in
            let anchor = base.appendingPathComponent("container", isDirectory: true)
            let moved = base.appendingPathComponent("original", isDirectory: true)
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
            var didReplaceAnchor = false
            let result = try SecureCacheDirectory.openOrCreateVerifiedDirectory(
                at: anchor.appendingPathComponent("cache"), trustAnchor: anchor,
                directoryStat: { descriptor, info in
                    let status = fstat(descriptor, &info)
                    if !didReplaceAnchor {
                        didReplaceAnchor = true
                        do {
                            try FileManager.default.moveItem(at: anchor, to: moved)
                            try FileManager.default.createDirectory(
                                at: anchor,
                                withIntermediateDirectories: false
                            )
                        } catch {
                            Issue.record(error)
                            return -1
                        }
                    }
                    return status
                }
            )
            defer { close(result.descriptor) }
            #expect(path(of: result.descriptor) ==
                physicalPath(moved.appendingPathComponent("cache")))
            #expect(!FileManager.default
                .fileExists(atPath: anchor.appendingPathComponent("cache").path))
            #expect(result.leafWasFreshlyCreated)
        }
    }
}
