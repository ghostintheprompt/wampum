import Foundation
import Darwin

/// A check owns a process group. Children that deliberately setsid/setpgid can escape it.
public final class OwnedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    public init(plan: CommandPlan, directory: URL, log: URL, completion: @escaping @Sendable (Int32, Bool) -> Void) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw WorkbenchError.invalid("Cannot initialize check file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw WorkbenchError.invalid("Cannot initialize check attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        func checked(_ result: Int32) throws { if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) } }
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600))
        try checked(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
        let argv = ([plan.executable.path] + plan.arguments).map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var arguments = argv + [nil], env = environment + [nil], spawned: pid_t = 0
        try checked(posix_spawn(&spawned, plan.executable.path, &actions, &attributes, &arguments, &env))
        pid = spawned
        let child = spawned
        DispatchQueue.global(qos: .utility).async { [self] in
            // Keep the leader unreaped until cleanup so its group ID cannot be reused.
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            lock.lock()
            if result == 0 { _ = kill(-pid, SIGTERM) }
            lock.unlock()
            if result == 0 { Thread.sleep(forTimeInterval: 0.15) }
            lock.lock()
            if result == 0 { _ = kill(-pid, SIGKILL) }
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(child, &status, 0) } while waited == -1 && errno == EINTR
            let stopped = cancelled
            pid = 0
            lock.unlock()
            let signal = status & 0x7f
            let code: Int32 = waited == -1 ? -1 : signal == 0 ? (status >> 8) & 0xff : 128 + signal
            completion(code, stopped)
        }
    }
    public func forceStop() {
        lock.lock();defer{lock.unlock()}
        if pid > 0 {cancelled=true;_ = kill(-pid,SIGKILL)}
    }
    public func terminate() {
        lock.lock()
        guard pid > 0 else { lock.unlock(); return }
        cancelled = true
        _ = kill(-pid, SIGTERM)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) { [self] in
            lock.lock(); defer { lock.unlock() }
            if pid > 0 { _ = kill(-pid, SIGKILL) }
        }
    }
}
