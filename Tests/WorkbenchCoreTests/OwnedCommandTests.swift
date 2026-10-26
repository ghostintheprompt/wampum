import XCTest
import Darwin
@testable import WorkbenchCore

final class OwnedCommandTests: XCTestCase {
    func testStopKillsChildrenAndGrandchildrenIgnoringTERM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tree.py"), pids = root.appendingPathComponent("pids")
        try Data("""
        import os,sys,signal,subprocess,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        with open(sys.argv[1], 'a') as f: f.write(str(os.getpid())+'\\n')
        depth=int(sys.argv[2])
        if depth: subprocess.Popen([sys.executable,__file__,sys.argv[1],str(depth-1)])
        while True: time.sleep(0.1)
        """.utf8).write(to: script)
        let done = expectation(description: "stopped group")
        let plan = try CommandPlan.make(command: "/usr/bin/python3 '\(script.path)' '\(pids.path)' 2", externalAllowed: true)
        let command = try OwnedCommand(plan: plan, directory: root, log: root.appendingPathComponent("log")) { code, stopped in
            XCTAssertTrue(stopped); XCTAssertEqual(code, 137); done.fulfill()
        }
        var children: [Int32] = []
        for _ in 0..<150 {
            children = ((try? String(contentsOf: pids)) ?? "").split(separator: "\n").compactMap { Int32($0) }
            if children.count == 3 { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        defer { command.terminate(); children.forEach { _ = kill($0, SIGKILL) } }
        XCTAssertEqual(children.count, 3)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        command.terminate(); command.terminate()
        await fulfillment(of: [done], timeout: 5)
        for _ in 0..<100 { if children.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        for pid in children { XCTAssertEqual(kill(pid, 0), -1, "surviving group member \(pid)") }
        XCTAssertTrue(unrelated.isRunning)
    }
    func testNaturalExitCleansBackgroundChildAndPreservesExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = expectation(description: "completed group"), pids = root.appendingPathComponent("pid")
        let plan = try CommandPlan.make(command: "/bin/sleep 30 & echo $! > '\(pids.path)'; printf OUTPUT; exit 7", externalAllowed: true)
        let command = try OwnedCommand(plan: plan, directory: root, log: root.appendingPathComponent("log")) { code, stopped in
            XCTAssertFalse(stopped); XCTAssertEqual(code, 7); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pids).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { command.terminate(); _ = kill(pid, SIGKILL) }
        for _ in 0..<100 { if kill(pid, 0) == -1 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("log")), "OUTPUT")
    }
}
