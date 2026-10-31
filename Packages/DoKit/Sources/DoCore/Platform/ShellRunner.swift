import Darwin
import Foundation

public enum ShellRunnerError: Error, LocalizedError {
    case spawnFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let code): "Could not start the shell (\(String(cString: strerror(code))))."
        }
    }
}

/// Runs shell commands for the agent's `bash` channel.
///
/// Commands run in `zsh -lc` from a dedicated workspace directory, in their own process group,
/// with stdin on /dev/null (so anything interactive — `sudo`, pagers, prompts — fails fast
/// instead of hanging), stdout and stderr merged, and a hard timeout that kills the whole group.
public final class ShellRunner: Sendable {
    public let workingDirectory: URL
    public let timeout: Duration
    public let shell: String

    public init(workingDirectory: URL, timeout: Duration = .seconds(300), shell: String = "/bin/zsh") {
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.shell = shell
    }

    public static var defaultWorkspace: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Do/Workspace", directoryHint: .isDirectory)
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extraPath.filter { !path.contains($0) } + path).joined(separator: ":")
        env["TERM"] = "dumb"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env.removeValue(forKey: "SUDO_ASKPASS")
        return env
    }

    public func run(_ command: String) async throws -> ShellResult {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ShellRunnerError.spawnFailed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group (pgid = child pid) and close every other inherited descriptor.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = [shell, "-lc", command]
        let envp = Self.environment().map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnStatus = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in
                posix_spawn(&pid, shell, &actions, &attributes, cArgv, cEnvp)
            }
        }
        close(writeFD)
        guard spawnStatus == 0 else {
            close(readFD)
            throw ShellRunnerError.spawnFailed(spawnStatus)
        }

        let collector = OutputCollector()
        let reader = Task.detached { () -> Void in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readFD, &buffer, buffer.count)
                if n > 0 {
                    collector.append(buffer[0 ..< n])
                } else if n == 0 || errno != EINTR {
                    break
                }
            }
            close(readFD)
        }

        let timedOut = Flag()
        let childPID = pid
        let watchdog = Task.detached { [timeout] in
            try await Task.sleep(for: timeout)
            timedOut.set()
            Self.killGroup(childPID)
        }

        let status: Int32 = await withTaskCancellationHandler {
            await Self.waitForExit(childPID)
        } onCancel: {
            Self.killGroup(childPID)
        }
        watchdog.cancel()
        // Background children may keep the pipe open; don't wait on them forever.
        let drained = Task.detached { await reader.value }
        let drainDeadline = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            Self.killGroup(childPID)
        }
        await drained.value
        drainDeadline.cancel()

        try Task.checkCancellation()
        return ShellResult(output: collector.string, exitCode: status, timedOut: timedOut.value)
    }

    private static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                // WIFEXITED / WEXITSTATUS, WIFSIGNALED
                let exited = (status & 0x7F) == 0
                let code = exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
                continuation.resume(returning: code)
            }
        }
    }

    static func killGroup(_ pid: pid_t) {
        Darwin.kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            Darwin.kill(-pid, SIGKILL)
        }
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    /// Keep memory bounded for chatty commands; the model only sees the first 5,000 chars.
    private let cap = 4 << 20

    func append(_ chunk: ArraySlice<UInt8>) {
        lock.withLock {
            if data.count < cap { data.append(contentsOf: chunk.prefix(cap - data.count)) }
        }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

private final class Flag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
