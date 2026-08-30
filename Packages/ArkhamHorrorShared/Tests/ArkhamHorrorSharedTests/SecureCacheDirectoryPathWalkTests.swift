@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectory/openOrCreateVerifiedDirectory(at:)`` never
/// leaks the intermediate directory descriptor it is walking when a later
/// path component fails to verify. Before the fix under test, a failure
/// from ``SecureCacheDirectory/openVerifiedComponent(parentFD:name:createIfMissing:)``
/// partway through the walk propagated immediately, skipping the
/// `close(currentFD)` call that every *successful* iteration performs —
/// silently leaking one file descriptor per failed call. A long-lived
/// process that repeatedly constructs (and fails to construct) a cache
/// directory under a corrupted/blocked path — for example, a persistent
/// misconfiguration that keeps retrying — would otherwise eventually
/// exhaust the process's file descriptor table.
@Suite("SecureCacheDirectory path-walk descriptor lifetime")
struct SecureCacheDirectoryPathWalkTests {
    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("PathWalkScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    /// The number of currently open file descriptors for this process, via
    /// `/dev/fd` (a Darwin-standard directory listing exactly one entry
    /// per open descriptor) — a real, external measurement rather than any
    /// instrumentation inside `SecureCacheDirectory` itself, so this
    /// test observes the exact same resource a real descriptor leak would
    /// actually exhaust.
    private func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    @Test(
        "A mid-walk verification failure does not leak the parent directory descriptor"
    )
    func failedWalkDoesNotLeakDescriptors() throws {
        try withScratchDirectory { base in
            // Plant a regular *file* (not a directory) at an intermediate
            // path component: every attempt to open a cache root nested
            // underneath it must fail verification at that exact
            // component, repeatedly, without ever reaching the walk's
            // final `return`.
            let blockingFile = base.appendingPathComponent("blocking-file")
            try Data("not a directory".utf8).write(to: blockingFile)
            let target = blockingFile
                .appendingPathComponent("nested", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)

            // A moderate iteration count: each iteration performs several
            // real synchronous `openat`/`fstat`/`close` syscalls, so this
            // stays fast even on a CI runner with much higher filesystem
            // latency than local storage, while still being large enough
            // that a genuine one-descriptor-per-call leak produces a
            // clearly linear, deterministic, easily-detected signal.
            //
            // This whole test suite runs its tests in parallel by default,
            // so the process-wide `/dev/fd` count this test necessarily
            // relies on (there is no way to scope it to only this test's
            // own descriptors) can be transiently nudged by whatever
            // unrelated concurrently-running tests happen to have open at
            // the exact instant `before`/`after` are sampled — a fixed
            // tolerance, however generous, was observed to fail
            // intermittently under the full ~1178-test suite (growth of
            // 8, 21, even 75 was observed across independent runs, purely
            // from sibling-test noise, with this test's own code path
            // leaking nothing).
            //
            // A single noisy sample cannot be told apart from a genuine
            // leak by its absolute size alone, but the two remain
            // trivially distinguishable across *repeated, independent*
            // measurement windows: a real leak in the code under test
            // reproduces the same large, roughly-`iterations`-sized
            // growth deterministically on every attempt (the code path is
            // unchanged between attempts), whereas transient noise from
            // whichever unrelated tests happen to be running concurrently
            // is essentially independent from one attempt to the next and
            // overwhelmingly unlikely to reproduce a spurious failure on
            // every one of several retries. So: retry the whole
            // measurement a bounded number of times, succeeding as soon
            // as any single attempt observes acceptably small growth, and
            // only failing (reporting the last attempt's numbers) if
            // every attempt observed growth at or above tolerance.
            let iterations = 40
            let tolerance = 20
            let maxAttempts = 5
            var lastBefore = -1
            var lastAfter = -1
            var sawAcceptableGrowth = false
            for attempt in 0 ..< maxAttempts {
                // A brief pause before re-measuring gives concurrently
                // running sibling tests a chance to close their own
                // transient descriptors, reducing (though never fully
                // eliminating) the chance of repeatedly sampling during
                // another test's own transient spike.
                if attempt > 0 {
                    Thread.sleep(forTimeInterval: 0.05)
                }

                // Warm up once outside the measured window: the very
                // first `/dev/fd` listing call itself can transiently
                // allocate descriptors (directory stream, etc.) that a
                // strict growth comparison would otherwise misattribute
                // to the code under test.
                _ = openFileDescriptorCount()
                let before = openFileDescriptorCount()

                for _ in 0 ..< iterations {
                    _ = try? SecureCacheDirectory.openOrCreateVerifiedDirectory(at: target)
                }

                let after = openFileDescriptorCount()
                lastBefore = before
                lastAfter = after
                if before >= 0, after >= 0, after - before < tolerance {
                    sawAcceptableGrowth = true
                    break
                }
            }

            #expect(lastBefore >= 0)
            #expect(lastAfter >= 0)
            #expect(
                sawAcceptableGrowth,
                """
                descriptor count grew by at least \(tolerance) over \(iterations) failed calls \
                on every one of \(maxAttempts) independent attempts (last attempt: \
                \(lastBefore) -> \(lastAfter))
                """
            )

            // A single confirmatory pass, outside the retry loop, proves
            // every one of the `iterations * maxAttempts` calls above
            // really did fail verification as expected (not, say, quietly
            // short-circuiting for an unrelated reason that happened to
            // also avoid opening descriptors).
            #expect(throws: AssetError.self) {
                _ = try SecureCacheDirectory.openOrCreateVerifiedDirectory(at: target)
            }
        }
    }

    /// A `directory` whose standardized, absolute path is exactly the
    /// filesystem root (`/`) has zero non-root path components, so the
    /// walk's `for component in components` loop never executes. Before
    /// the fix under test, this fell straight through to `return
    /// currentFD`, handing back an open descriptor to `/` itself as
    /// though it were a verified, cache-owned directory -- which would
    /// turn every later create/remove/enumerate call this package makes
    /// through that descriptor into an operation against the entire
    /// filesystem root. This must be rejected before opening anything.
    @Test("Opening the filesystem root itself as a cache directory is rejected")
    func rejectsFilesystemRootAsCacheDirectory() {
        let root = URL(fileURLWithPath: "/")
        #expect(throws: AssetError.self) {
            _ = try SecureCacheDirectory.openOrCreateVerifiedDirectory(at: root)
        }
    }

    /// A review finding flagged that the strict, per-component
    /// `O_NOFOLLOW` walk would incorrectly *reject* every real-world
    /// cache directory rooted at Darwin's `/var` compatibility symlink
    /// (`/var` -> `/private/var`) -- exactly the form every iOS
    /// container path (`/var/mobile/Containers/.../Library/Caches/...`)
    /// and every `NSTemporaryDirectory()`/`.cachesDirectory` result on
    /// both macOS and iOS-family systems actually uses, never the
    /// `/private/var/...` physical form. This proves the fix: a genuine,
    /// real (not simulated) path under the OS's own compatibility form is
    /// accepted and produces a fully usable, verified directory.
    @Test(
        """
        A real cache-style path under the OS's own `/var` compatibility symlink form (as \
        `NSTemporaryDirectory()` itself always returns on Darwin, never its `/private/var/...` \
        physical form) is accepted and produces a genuinely usable, fully-verified directory -- \
        the exact "iOS-family /var path" scenario a review flagged as being incorrectly rejected
        """
    )
    func acceptsRealWorldVarCompatibilitySymlinkPath() throws {
        let temporaryDirectory = NSTemporaryDirectory()
        // `NSTemporaryDirectory()` is documented to always return a path
        // rooted at exactly this compatibility form on every real Darwin
        // system (macOS and iOS-family alike); if some future OS ever
        // changed this, this precondition failing loudly is far better
        // than this test silently exercising an unintended code path.
        try #require(temporaryDirectory.hasPrefix("/var/"))
        let target = URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent(
                "ArkhamHorrorAssetCachePathWalkTest-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: target) }

        let descriptor = try SecureCacheDirectory.openOrCreateVerifiedDirectory(at: target)
        defer { close(descriptor) }
        #expect(descriptor >= 0)

        var info = stat()
        #expect(fstat(descriptor, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
    }

    /// A symlink planted at any position *other* than the exact,
    /// well-known top-level `/tmp`/`/var`/`/etc` compatibility names must
    /// still be rejected exactly as strictly as before this fix -- the
    /// fix's narrowness (only ever firing for the first path component,
    /// only for this fixed three-name set) must not have accidentally
    /// broadened into "silently follow any symlink component".
    @Test(
        "A non-well-known symlink planted at an intermediate path component is still rejected"
    )
    func stillRejectsArbitraryIntermediateSymlink() throws {
        try withScratchDirectory { base in
            let realDirectory = base.appendingPathComponent("real-target", isDirectory: true)
            try FileManager.default.createDirectory(
                at: realDirectory, withIntermediateDirectories: true
            )
            let symlinkPath = base.appendingPathComponent("not-a-well-known-name")
            try FileManager.default.createSymbolicLink(
                at: symlinkPath, withDestinationURL: realDirectory
            )
            let target = symlinkPath.appendingPathComponent("cache", isDirectory: true)
            #expect(throws: AssetError.self) {
                _ = try SecureCacheDirectory.openOrCreateVerifiedDirectory(at: target)
            }
        }
    }
}
