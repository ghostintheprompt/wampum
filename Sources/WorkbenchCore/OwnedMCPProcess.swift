import Foundation
import Darwin

/// Owns only the spawned transport's process group, never an existing user browser.
/// Descendants that deliberately leave that group require separate ownership tracking.
final class OwnedMCPProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    var identifier: pid_t? { lock.lock(); defer { lock.unlock() }; return pid > 0 ? pid : nil }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return pid > 0 }

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ result: Int32) throws {
            if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try checked(posix_spawn_file_actions_adddup2(&actions, stdin.fileDescriptor, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, stdout.fileDescriptor, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, stderr.fileDescriptor, STDERR_FILENO))
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var args = argv + [nil], vars = env + [nil], child: pid_t = 0
        try checked(posix_spawn(&child, executable.path, &actions, &attributes, &args, &vars))
        pid = child
        let leader = child
        DispatchQueue.global(qos: .utility).async { [self] in
            // Do not reap the leader until group cleanup: its PID reserves the group ID.
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            lock.lock()
            if result == 0 { _ = kill(-pid, SIGTERM) }
            lock.unlock()
            if result == 0 { Thread.sleep(forTimeInterval: 0.15) }
            lock.lock()
            if result == 0 { _ = kill(-pid, SIGKILL) }
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(leader, &status, 0) } while waited == -1 && errno == EINTR
            pid = 0
            lock.unlock()
        }
    }

    func terminate() {
        lock.lock()
        guard pid > 0 else { lock.unlock(); return }
        _ = kill(-pid, SIGTERM)
        lock.unlock()
        // Let the stdio adapter close its isolated browser before forced cleanup.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
            lock.lock(); defer { lock.unlock() }
            if pid > 0 { _ = kill(-pid, SIGKILL) }
        }
    }
}
