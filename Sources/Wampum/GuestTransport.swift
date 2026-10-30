import Foundation
import WorkbenchCore

/// A channel for running commands and moving files in the capture guest. The UTM guest agent
/// (`utmctl exec`/`file`) is the default; SSH is the fallback when the agent is not installed.
/// VM lifecycle (start) and USB attach are NOT part of this — those always go through utmctl.
protocol GuestTransport {
    func waitForReady(maxSeconds: Int) async -> Bool
    @discardableResult func exec(_ script: String, timeout: TimeInterval) async throws -> String
    func push(_ data: Data, to guestPath: String) async throws
    func pull(_ guestPath: String) async throws -> Data
}

/// Shared bounded Process executor used by both transports.
enum GuestProcess {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    @discardableResult
    static func run(_ executable: URL, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 40) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
                process.standardOutput = outPipe; process.standardError = errPipe
                if stdin != nil { process.standardInput = inPipe }
                do { try process.run() } catch { continuation.resume(throwing: Failure(message: "\(executable.lastPathComponent) failed to launch: \(error.localizedDescription)")); return }
                if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin); try? inPipe.fileHandleForWriting.close() }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); watchdog.cancel()
                if process.terminationStatus != 0 {
                    let msg = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(message: msg.isEmpty ? "\(executable.lastPathComponent) exited \(process.terminationStatus)" : msg)); return
                }
                continuation.resume(returning: out)
            }
        }
    }
}

/// SSH/SCP transport to the guest. Runs the same guest-side work as the utmctl transport,
/// so the capture flow is identical; only the channel differs. Non-interactive only
/// (BatchMode); set up key auth in the guest first.
struct SSHRunner: GuestTransport {
    let host: String
    let port: Int
    let user: String
    let identity: String?   // path to a private key, optional

    private let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    private func sshArgs(_ remote: [String]) -> [String] {
        var args = ["-p", String(port), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        if let identity, !identity.isEmpty { args += ["-i", identity] }
        args += ["\(user)@\(host)"]
        args += remote
        return args
    }

    // Build a safely-quoted remote path (guest paths are already validated to be simple).
    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func waitForReady(maxSeconds: Int) async -> Bool {
        let tries = max(1, maxSeconds / 5)
        for _ in 0..<tries {
            if let out = try? await exec("echo WAMPUM_READY", timeout: 8), out.contains("WAMPUM_READY") { return true }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return false
    }

    @discardableResult
    func exec(_ script: String, timeout: TimeInterval = 20) async throws -> String {
        guard !script.contains("\0") else { throw GuestProcess.Failure(message: "Invalid guest script.") }
        let out = try await GuestProcess.run(ssh, sshArgs(["bash", "-lc", script]), timeout: timeout)
        return String(decoding: out, as: UTF8.self)
    }

    func push(_ data: Data, to guestPath: String) async throws {
        guard UTMControl.isSafeGuestPath(guestPath) else { throw GuestProcess.Failure(message: "Unsafe guest destination path.") }
        // Stream stdin to a remote file; avoids a temp file on either side.
        _ = try await GuestProcess.run(ssh, sshArgs(["cat > \(SSHRunner.quote(guestPath))"]), stdin: data)
    }

    func pull(_ guestPath: String) async throws -> Data {
        guard UTMControl.isSafeGuestPath(guestPath) else { throw GuestProcess.Failure(message: "Unsafe guest source path.") }
        return try await GuestProcess.run(ssh, sshArgs(["cat \(SSHRunner.quote(guestPath))"]), timeout: 60)
    }
}
