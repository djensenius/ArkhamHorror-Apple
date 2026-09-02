@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

/// Coverage for ``DeviceTransitionPolicy`` -- the pure, injectable device-
/// identity seam ``SecureCacheDirectory/openOrCreateVerifiedDirectory(at:)``'s
/// path walk uses instead of a single fixed "must match the filesystem
/// root's own device" requirement. A prior review found that requiring
/// every path component to share `/`'s own device incorrectly rejected
/// every real-world iOS-family container path, since `/` (System volume)
/// and `/var` (Data volume, reached only via the fixed `/var` ->
/// `/private/var` compatibility symlink) are two genuinely different
/// physical APFS volumes there, unified into one path namespace purely by
/// Darwin's own volume-group firmlink mechanism -- not by this cache. This
/// package cannot mount a second physical volume inside a hosted CI/test
/// environment to reproduce that topology directly, so ``DeviceTransitionPolicy``
/// is deliberately factored out as a pure, filesystem-independent type:
/// every scenario below exercises its actual decision logic with entirely
/// synthetic `dev_t` values, proving the policy itself (same-device
/// sequences always accepted; exactly one transition accepted; a second,
/// later transition rejected) without needing real multi-volume hardware
/// at all -- the same idea a review explicitly asked for ("injectable
/// production-anchor tests plus device acceptance seam").
@Suite("DeviceTransitionPolicy")
struct DeviceTransitionPolicyTests {
    @Test("A sequence entirely on the root device is accepted throughout, with no transition")
    func sameDeviceSequenceNeverTransitions() {
        let rootDevice: dev_t = 7
        let policy = DeviceTransitionPolicy(rootDevice: rootDevice)
        #expect(policy.accepts(rootDevice))
        #expect(policy.accepts(rootDevice))
        #expect(policy.accepts(rootDevice))
        #expect(!policy.hasTransitioned)
        #expect(policy.currentDevice == rootDevice)
    }

    @Test(
        """
        Exactly one transition to a second device is accepted (the real iOS-family System/Data \
        volume-group split), and every subsequent component on that new device is also accepted
        """
    )
    func singleTransitionIsAccepted() {
        let systemDevice: dev_t = 1
        let dataDevice: dev_t = 2
        let policy = DeviceTransitionPolicy(rootDevice: systemDevice)
        #expect(policy.accepts(systemDevice))
        #expect(policy.accepts(dataDevice))
        #expect(policy.hasTransitioned)
        #expect(policy.currentDevice == dataDevice)
        // Every component below the transition point stays on the new
        // (Data volume) device -- accepted as "no further transition".
        #expect(policy.accepts(dataDevice))
        #expect(policy.accepts(dataDevice))
    }

    @Test(
        """
        A second, later transition to a third device is rejected -- this is what actually \
        distinguishes a genuine bind-mount/volume substitution planted inside the subtree from \
        the one legitimate System/Data split
        """
    )
    func secondTransitionIsRejected() {
        let systemDevice: dev_t = 1
        let dataDevice: dev_t = 2
        let attackerMountDevice: dev_t = 3
        let policy = DeviceTransitionPolicy(rootDevice: systemDevice)
        #expect(policy.accepts(systemDevice))
        #expect(policy.accepts(dataDevice))
        #expect(!policy.accepts(attackerMountDevice))
        // The rejection must not itself silently "accept" the attacker's
        // device as the new baseline: the policy's own recorded device
        // stays at the last legitimately-accepted one.
        #expect(policy.currentDevice == dataDevice)
    }

    @Test("Reverting from the transitioned device back to the original root device is rejected")
    func revertingToOriginalDeviceAfterTransitionIsRejected() {
        let systemDevice: dev_t = 1
        let dataDevice: dev_t = 2
        let policy = DeviceTransitionPolicy(rootDevice: systemDevice)
        #expect(policy.accepts(systemDevice))
        #expect(policy.accepts(dataDevice))
        // Once transitioned, going back to the original device is itself
        // a second transition and must be rejected exactly as strictly
        // as transitioning to any other, unrelated third device.
        #expect(!policy.accepts(systemDevice))
    }

    @Test(
        """
        openVerifiedComponent(devicePolicy:), seeded with a synthetic "already on a different \
        device" policy, accepts a real directory whose real device becomes this walk's one \
        tolerated transition -- proving the walk's own integration with the policy, not merely \
        the policy in isolation
        """
    )
    func openVerifiedComponentAcceptsOneTransitionViaDevicePolicy() throws {
        try withScratchDirectory { base in
            let rootFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            #expect(rootFD >= 0)
            defer { close(rootFD) }
            // Seed the policy with a synthetic device that can never
            // match this real host's own device -- simulating "the walk
            // started on the System volume" without needing one to
            // actually exist. The real `nested` directory's own real
            // device then becomes this policy's one tolerated
            // transition.
            let policy = DeviceTransitionPolicy(rootDevice: dev_t.max)
            let descriptor = try SecureCacheDirectory.openVerifiedComponent(
                parentFD: rootFD,
                name: "nested",
                createIfMissing: true,
                devicePolicy: policy,
                trustedOwnerUID: getuid()
            ).descriptor
            defer { close(descriptor) }
            #expect(descriptor >= 0)
            #expect(policy.hasTransitioned)
        }
    }

    @Test(
        """
        openVerifiedComponent(devicePolicy:) rejects a real directory when the policy has \
        already spent its one tolerated transition on an unrelated synthetic device
        """
    )
    func openVerifiedComponentRejectsSecondTransitionViaDevicePolicy() throws {
        try withScratchDirectory { base in
            let rootFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            #expect(rootFD >= 0)
            defer { close(rootFD) }
            // Seed the policy as already having transitioned once (from
            // one synthetic device to a second, different synthetic
            // device) -- this real directory's own real device would be
            // a *second* transition and must be rejected.
            let policy = DeviceTransitionPolicy(rootDevice: dev_t.max)
            #expect(policy.accepts(dev_t.max - 1))
            #expect(throws: AssetError.self) {
                let descriptor = try SecureCacheDirectory.openVerifiedComponent(
                    parentFD: rootFD,
                    name: "nested",
                    createIfMissing: true,
                    devicePolicy: policy,
                    trustedOwnerUID: getuid()
                ).descriptor
                close(descriptor)
            }
        }
    }

    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceTransitionPolicyScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }
}
