import Darwin

extension SubprocessDeadlineGuard {
    static func spawnConfiguredChild(
        executablePath: String,
        argumentPointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        environmentPointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> SubprocessDeadlineChild {
        let nullDescriptor = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw SubprocessDeadlineGuardError.launchFailed(code: errno)
        }
        defer { close(nullDescriptor) }

        var fileActions = try makeSpawnFileActions(
            nullDescriptor: nullDescriptor
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes = try makeSpawnAttributes()
        defer { posix_spawnattr_destroy(&attributes) }

        var pid: pid_t = 0
        try requireSpawnSuccess(
            posix_spawn(
                &pid,
                executablePath,
                &fileActions,
                &attributes,
                argumentPointer,
                environmentPointer
            )
        )
        let child = SubprocessDeadlineChild(
            pid: pid,
            processGroupID: pid
        )
        guard getpgid(pid) == child.processGroupID else {
            bestEffortCleanup(child)
            throw SubprocessDeadlineGuardError.launchFailed(code: EPERM)
        }
        return child
    }

    private static func makeSpawnFileActions(
        nullDescriptor: Int32
    ) throws -> posix_spawn_file_actions_t? {
        var fileActions: posix_spawn_file_actions_t?
        try requireSpawnSuccess(
            posix_spawn_file_actions_init(&fileActions)
        )
        do {
            try configureOutputDiscard(
                fileActions: &fileActions,
                nullDescriptor: nullDescriptor
            )
            return fileActions
        } catch {
            posix_spawn_file_actions_destroy(&fileActions)
            throw error
        }
    }

    private static func configureOutputDiscard(
        fileActions: inout posix_spawn_file_actions_t?,
        nullDescriptor: Int32
    ) throws {
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            guard nullDescriptor != descriptor else { continue }
            try requireSpawnSuccess(
                posix_spawn_file_actions_adddup2(
                    &fileActions,
                    nullDescriptor,
                    descriptor
                )
            )
        }
        if nullDescriptor != STDOUT_FILENO, nullDescriptor != STDERR_FILENO {
            try requireSpawnSuccess(
                posix_spawn_file_actions_addclose(
                    &fileActions,
                    nullDescriptor
                )
            )
        }
    }

    private static func makeSpawnAttributes() throws -> posix_spawnattr_t? {
        var attributes: posix_spawnattr_t?
        try requireSpawnSuccess(posix_spawnattr_init(&attributes))
        do {
            // Isolate termination and undo the test host's inherited SIGTERM state.
            try requireSpawnSuccess(
                posix_spawnattr_setflags(
                    &attributes,
                    Int16(
                        POSIX_SPAWN_SETPGROUP |
                            POSIX_SPAWN_SETSIGDEF |
                            POSIX_SPAWN_SETSIGMASK
                    )
                )
            )
            try requireSpawnSuccess(
                posix_spawnattr_setpgroup(&attributes, 0)
            )
            try configureChildSignals(attributes: &attributes)
            return attributes
        } catch {
            posix_spawnattr_destroy(&attributes)
            throw error
        }
    }

    private static func configureChildSignals(
        attributes: inout posix_spawnattr_t?
    ) throws {
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        try requireSpawnSuccess(
            posix_spawnattr_setsigdefault(
                &attributes,
                &defaultSignals
            )
        )

        var signalMask = sigset_t()
        try requireSpawnSuccess(
            pthread_sigmask(SIG_SETMASK, nil, &signalMask)
        )
        sigdelset(&signalMask, SIGTERM)
        try requireSpawnSuccess(
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        )
    }

    private static func requireSpawnSuccess(_ result: Int32) throws {
        guard result == 0 else {
            throw SubprocessDeadlineGuardError.launchFailed(code: result)
        }
    }
}
