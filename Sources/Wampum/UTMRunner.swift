import Foundation
import WorkbenchCore

/// Host-side executor for `utmctl`. The pure command/verification logic lives in
/// `UTMControl` (WorkbenchCore); this runs the commands with `Process`, including the
/// stdin (file push) and stdout-to-file (file pull) paths. Learned from live use: `exec`
/// runs a program directly, so guest shell work goes through `/bin/bash -lc`, and `exec`
/// has a short stdout timeout, so slow work is backgrounded in the guest and its result is
/// retrieved with `file pull` rather than read from exec stdout.
struct UTMRunner {
    let utmctl: URL
    let vm: String

    enum RunError: LocalizedError { case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil } }

    /// Run utmctl with the given args. Optional stdin data (for `file push`). Returns stdout.
    @discardableResult
    func run(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 40) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = self.utmctl
                process.arguments = args
                let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
                process.standardOutput = outPipe; process.standardError = errPipe
                if stdin != nil { process.standardInput = inPipe }
                do { try process.run() } catch { continuation.resume(throwing: RunError.failed("utmctl failed to launch: \(error.localizedDescription)")); return }
                if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin); try? inPipe.fileHandleForWriting.close() }
                // Bound the wait; utmctl exec can hang on a slow guest command.
                let deadline = DispatchTime.now() + timeout
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); watchdog.cancel()
                if process.terminationStatus != 0 {
                    let msg = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: RunError.failed(msg.isEmpty ? "utmctl exited \(process.terminationStatus)" : msg)); return
                }
                continuation.resume(returning: out)
            }
        }
    }

    /// Run a bash command in the guest via `exec --cmd /bin/bash -lc "..."`. For fast commands.
    @discardableResult
    func guestBash(_ script: String, timeout: TimeInterval = 20) async throws -> String {
        guard !vm.isEmpty, !vm.contains("\0"), !vm.contains("\n") else { throw RunError.failed("Invalid VM identifier.") }
        guard !script.isEmpty, !script.contains("\0") else { throw RunError.failed("Empty guest script.") }
        // exec runs a program directly, so the shell is explicit: --cmd /bin/bash -lc "<script>".
        let args = ["exec", "--hide", vm, "--cmd", "/bin/bash", "-lc", script]
        let out = try await run(args, timeout: timeout)
        return String(decoding: out, as: UTF8.self)
    }

    func start() async throws { _ = try await run(try UTMControl.argv(vm: vm, .start)) }
    func usbConnect(_ device: String) async throws { _ = try await run(["usb", "connect", "--hide", vm, device]) }
    func push(_ data: Data, to guestPath: String) async throws { _ = try await run(try UTMControl.argv(vm: vm, .filePush(guestPath: guestPath)), stdin: data) }
    func pull(_ guestPath: String) async throws -> Data { try await run(try UTMControl.argv(vm: vm, .filePull(guestPath: guestPath)), timeout: 60) }

    /// Wait until the guest agent answers (bounded). Returns true when ready.
    func waitForAgent(maxSeconds: Int = 180) async -> Bool {
        let tries = max(1, maxSeconds / 5)
        for _ in 0..<tries {
            if let out = try? await guestBash("echo WAMPUM_READY", timeout: 8), out.contains("WAMPUM_READY") { return true }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return false
    }
}

extension UTMRunner: GuestTransport {
    func waitForReady(maxSeconds: Int) async -> Bool { await waitForAgent(maxSeconds: maxSeconds) }
    func exec(_ script: String, timeout: TimeInterval) async throws -> String { try await guestBash(script, timeout: timeout) }
}
