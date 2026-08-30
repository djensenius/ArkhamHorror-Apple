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

            // Warm up once outside the measured window: the very first
            // `/dev/fd` listing call itself can transiently allocate
            // descriptors (directory stream, etc.) that a strict "zero
            // growth" comparison would otherwise misattribute to the code
            // under test.
            _ = openFileDescriptorCount()
            let before = openFileDescriptorCount()

            // A moderate iteration count, deliberately compared against an
            // *absolute* (not per-iteration-proportional) growth
            // tolerance rather than exact equality: this whole test suite
            // runs its tests in parallel by default, so unrelated tests
            // can transiently hold a small, bounded number of their own
            // descriptors open at the exact moment `before`/`after` are
            // sampled here. A real one-descriptor-per-call leak grows
            // linearly with the iteration count and so clears even a
            // generous fixed tolerance after only a few dozen calls,
            // while genuinely leak-free code stays comfortably under it
            // regardless of whatever unrelated concurrent activity is
            // happening elsewhere in the process. The iteration count
            // itself is kept modest (each iteration performs several real
            // synchronous `openat`/`fstat`/`close` syscalls) so this test
            // stays fast even on a CI runner with much higher filesystem
            // latency than local storage.
            let iterations = 40
            let tolerance = 8
            for _ in 0 ..< iterations {
                #expect(throws: AssetError.self) {
                    _ = try SecureCacheDirectory.openOrCreateVerifiedDirectory(at: target)
                }
            }

            let after = openFileDescriptorCount()
            #expect(before >= 0)
            #expect(after >= 0)
            #expect(
                after - before < tolerance,
                "descriptor count grew by \(after - before) over \(iterations) failed calls"
            )
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
}
