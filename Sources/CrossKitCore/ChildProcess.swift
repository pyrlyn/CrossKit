import Foundation
import Darwin

public enum ChildProcessError: Error, LocalizedError {
    case pipeFailed(Int32)
    case spawnFailed(String, Int32)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .pipeFailed(let code): return "pipe() failed: \(String(cString: strerror(code)))"
        case .spawnFailed(let path, let code): return "Cannot launch \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let code): return "Write to server failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Process groups of running servers, so everything can be killed when the host exits.
public enum ProcessRegistry {
    private static let lock = NSLock()
    private static var groups = Set<pid_t>()

    static func register(_ pgid: pid_t) { lock.lock(); groups.insert(pgid); lock.unlock() }
    static func unregister(_ pgid: pid_t) { lock.lock(); groups.remove(pgid); lock.unlock() }

    public static func activeGroups() -> [pid_t] {
        lock.lock(); defer { lock.unlock() }
        return Array(groups)
    }

    public static func killAll() {
        for group in activeGroups() { kill(-group, SIGKILL) }
    }

    /// True if any process still belongs to the process group.
    public static func groupIsAlive(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }
}

/// A child process started with posix_spawn in its own process group, with piped stdio.
/// Using a dedicated group lets us terminate helper processes (e.g. proc-macro servers) too.
public final class ChildProcess: @unchecked Sendable {
    public let pid: pid_t
    public let executable: String
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let lock = NSLock()
    private var exitCode: Int32?
    private let exited = DispatchSemaphore(value: 0)
    private let writeLock = NSLock()
    private var stdinClosed = false

    /// - Parameters:
    ///   - onStdout/onStderr: called on background threads with chunks; empty Data signals EOF.
    ///   - onExit: called once with the wait status code (exit code, or 128+signal).
    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?,
                onStdout: @escaping @Sendable (Data) -> Void,
                onStderr: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        signal(SIGPIPE, SIG_IGN)
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw ChildProcessError.pipeFailed(errno)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals: sigset_t = (sigset_t(1) << sigset_t(SIGPIPE - 1)) | (sigset_t(1) << sigset_t(SIGTERM - 1))
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noMask: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &noMask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw ChildProcessError.spawnFailed(executable, rc)
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        pid = child
        self.executable = executable
        stdinFD = inPipe[1]
        stdoutFD = outPipe[0]
        stderrFD = errPipe[0]
        ProcessRegistry.register(child)

        Self.startReader(fd: stdoutFD, name: "stdout", handler: onStdout)
        Self.startReader(fd: stderrFD, name: "stderr", handler: onStderr)
        let waiter = Thread { [pid = child] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let signal = status & 0x7f
            let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            // Leader gone: reap any helpers left in its group.
            kill(-pid, SIGKILL)
            ProcessRegistry.unregister(pid)
            self.lock.lock(); self.exitCode = code; self.lock.unlock()
            self.exited.signal()
            onExit(code)
        }
        waiter.name = "CrossKit.wait.\(child)"
        waiter.qualityOfService = .userInitiated
        waiter.start()
    }

    deinit {
        closeStdin()
    }

    private static func startReader(fd: Int32, name: String, handler: @escaping @Sendable (Data) -> Void) {
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    handler(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            handler(Data())
        }
        thread.name = "CrossKit.\(name)"
        thread.start()
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode == nil
    }

    public var terminationStatus: Int32? {
        lock.lock(); defer { lock.unlock() }
        return exitCode
    }

    public func write(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !stdinClosed else { throw ChildProcessError.writeFailed(EBADF) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(stdinFD, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ChildProcessError.writeFailed(errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    public func closeStdin() {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        close(stdinFD)
    }

    /// Blocks up to `timeout` seconds for exit. Returns true if the process exited.
    public func waitForExit(timeout: TimeInterval) -> Bool {
        if !isRunning { return true }
        if exited.wait(timeout: .now() + timeout) == .success {
            exited.signal() // allow other waiters
            return true
        }
        return false
    }

    public func terminateGroup() { kill(-pid, SIGTERM) }
    public func killGroup() { kill(-pid, SIGKILL) }
}
