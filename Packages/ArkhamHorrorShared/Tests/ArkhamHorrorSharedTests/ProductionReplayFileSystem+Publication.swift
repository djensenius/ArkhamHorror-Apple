import Darwin
import Foundation

private enum ProductionReplayPublicationMode {
    case exchange(previous: ProductionReplayArtifactIdentity)
    case moveExclusive
}

extension ProductionReplayFileSystem {
    static func publish(
        _ artifact: ProductionReplayStagingArtifact,
        from staging: ProductionReplayStagingDestination,
        to destination: ProductionReplayDestination,
        beforeMove: ProductionReplayPublicationHook
    ) throws -> ProductionReplayPublishedArtifact {
        let currentDestination = try validateFinalDestination(
            destination.finalURL
        )
        guard currentDestination.parent.identity ==
            destination.parent.identity
        else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        let mode = try publicationMode(for: destination)
        try validateStagingArtifact(
            artifact,
            named: staging.name,
            parent: destination.parent
        )
        try beforeMove()
        try moveForPublication(
            staging,
            to: destination,
            mode: mode
        )
        do {
            try validatePublishedArtifact(
                destination,
                expected: artifact
            )
        } catch {
            let validationError = error
            try rollbackPublication(
                staging,
                from: destination,
                mode: mode
            )
            throw validationError
        }
        return ProductionReplayPublishedArtifact(
            identity: artifact.identity,
            data: artifact.data
        )
    }

    private static func validateStagingArtifact(
        _ artifact: ProductionReplayStagingArtifact,
        named name: String,
        parent: ProductionReplayDirectoryHandle
    ) throws {
        let observed = try readStableArtifact(
            descriptor: artifact.descriptor,
            parentIdentity: parent.identity
        )
        guard ProductionReplayArtifactIdentity(observed.snapshot) ==
            artifact.identity,
            observed.data == artifact.data
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        try validateArtifactPath(
            name,
            parent: parent,
            expected: observed.snapshot
        )
    }

    private static func validatePublishedArtifact(
        _ destination: ProductionReplayDestination,
        expected artifact: ProductionReplayStagingArtifact
    ) throws {
        let before = try artifactPathSnapshot(
            destination.finalName,
            parent: destination.parent
        )
        guard ProductionReplayArtifactIdentity(before) ==
            artifact.identity
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        let observed = try readStableArtifact(
            descriptor: artifact.descriptor,
            parentIdentity: destination.parent.identity
        )
        guard ProductionReplayArtifactIdentity(observed.snapshot) ==
            artifact.identity,
            observed.data == artifact.data
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        try validateArtifactPath(
            destination.finalName,
            parent: destination.parent,
            expected: observed.snapshot
        )
    }

    private static func publicationMode(
        for destination: ProductionReplayDestination
    ) throws -> ProductionReplayPublicationMode {
        var info = stat()
        if fstatat(
            destination.parent.descriptor,
            destination.finalName,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard isRegular(info),
                  info.st_dev == destination.parent.identity.device
            else {
                throw ProductionReplayDriverError
                    .resultDestinationNotRegular
            }
            return .exchange(
                previous: ProductionReplayArtifactIdentity(info)
            )
        }
        guard errno == ENOENT else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return .moveExclusive
    }

    private static func moveForPublication(
        _ staging: ProductionReplayStagingDestination,
        to destination: ProductionReplayDestination,
        mode: ProductionReplayPublicationMode
    ) throws {
        let flags = switch mode {
        case .exchange:
            UInt32(RENAME_SWAP)
        case .moveExclusive:
            UInt32(RENAME_EXCL)
        }
        guard renameatx_np(
            destination.parent.descriptor,
            staging.name,
            destination.parent.descriptor,
            destination.finalName,
            flags
        ) == 0 else {
            throw ProductionReplayDriverError.resultPublishFailed(errno)
        }
    }

    private static func rollbackPublication(
        _ staging: ProductionReplayStagingDestination,
        from destination: ProductionReplayDestination,
        mode: ProductionReplayPublicationMode
    ) throws {
        switch mode {
        case let .exchange(previous):
            guard renameatx_np(
                destination.parent.descriptor,
                staging.name,
                destination.parent.descriptor,
                destination.finalName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw ProductionReplayDriverError.resultPublishFailed(errno)
            }
            let restored = try artifactPathSnapshot(
                destination.finalName,
                parent: destination.parent
            )
            guard ProductionReplayArtifactIdentity(restored) == previous else {
                throw ProductionReplayDriverError.resultPublishFailed(ESTALE)
            }
        case .moveExclusive:
            guard renameatx_np(
                destination.parent.descriptor,
                destination.finalName,
                destination.parent.descriptor,
                staging.name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw ProductionReplayDriverError.resultPublishFailed(errno)
            }
            var info = stat()
            guard fstatat(
                destination.parent.descriptor,
                destination.finalName,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT else {
                throw ProductionReplayDriverError.resultPublishFailed(ESTALE)
            }
        }
    }
}
