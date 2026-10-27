import XCTest
import Darwin
@testable import WorkbenchCore

final class MCPProcessTests: XCTestCase {
    private func fixture(_ root: URL) throws -> URL {
        let script = root.appendingPathComponent("owned-server.py")
        try Data(#"""
import os,sys,json,signal,subprocess,time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
with open(sys.argv[1],'a') as f:
 f.write(str(os.getpid())+':'+str(os.getpgrp())+'\n')
depth=int(sys.argv[2])
if depth:
 subprocess.Popen([sys.executable,__file__,sys.argv[1],str(depth-1),'worker'],stdin=subprocess.DEVNULL)
if 'worker' not in sys.argv:
 for line in sys.stdin:
  request=json.loads(line)
  if 'id' not in request: continue
  if request['method']=='hang': continue
  if request['method']=='exit': sys.exit(7)
  value={'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'owned-fixture','version':'1'}}
  print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':value}),flush=True)
while True: time.sleep(0.05)
"""#.utf8).write(to: script)
        return script
    }
    private func members(_ file: URL) async throws -> [(pid: Int32, group: Int32)] {
        var found: [(Int32, Int32)] = []
        for _ in 0..<150 {
            found = ((try? String(contentsOf: file)) ?? "").split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":"); guard parts.count == 2,
                let pid = Int32(parts[0]), let group = Int32(parts[1]) else { return nil }
                return (pid, group)
            }
            if found.count == 3 { return found }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw WorkbenchError.invalid("Owned fixture did not register its complete tree")
    }
    private func assertGone(_ pids: [Int32]) async throws {
        for _ in 0..<300 {
            if pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1, "Owned process survived: \(pid)") }
    }
    func testDisconnectCleansTERMResistantTreeAndPendingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try fixture(root), file = root.appendingPathComponent("members")
        let connection = MCPConnection()
        try await connection.start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: [script.path, file.path, "2"], directory: root, localOnly: true)
        let tree = try await members(file)
        defer { tree.forEach { _ = kill($0.pid, SIGKILL) } }
        XCTAssertEqual(Set(tree.map(\.group)), Set([tree[0].pid]))
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let hanging = Task { try await connection.request("hang", timeout: 10) }
        try await Task.sleep(nanoseconds: 40_000_000)
        let stopping=Task {await connection.stop()}
        stopping.cancel()
        for _ in 0..<100 {if await connection.ownedProcessIdentifier() == nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        let repeatedStop=await connection.stop()
        XCTAssertTrue(repeatedStop)
        XCTAssertTrue(tree.allSatisfy {kill($0.pid,0) == -1},"Repeated Stop returned before the first cleanup finished")
        let stopped=await stopping.value
        XCTAssertTrue(stopped,"Cancelled callers still wait for transport cleanup")
        await connection.stop()
        do { _ = try await hanging.value; XCTFail("Pending request should fail on disconnect") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disconnected"), error.localizedDescription) }
        try await assertGone(tree.map(\.pid))
        XCTAssertTrue(unrelated.isRunning)
        // A delayed cleanup from the old transport must not affect its replacement.
        let next = root.appendingPathComponent("replacement")
        try await connection.start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: [script.path, next.path, "2"], directory: root, localOnly: true)
        let replacement = try await members(next)
        defer { replacement.forEach { _ = kill($0.pid, SIGKILL) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let ready = try await connection.request("ready")
        XCTAssertEqual(ready["serverInfo"]?["name"]?.string, "owned-fixture")
        XCTAssertTrue(replacement.allSatisfy { kill($0.pid, 0) == 0 })
        await connection.stop()
        try await assertGone(replacement.map(\.pid))
    }
    func testNaturalServerExitCleansInheritedPipeHolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try fixture(root), file = root.appendingPathComponent("members")
        let connection = MCPConnection()
        try await connection.start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: [script.path, file.path, "2"], directory: root, localOnly: false)
        let tree = try await members(file)
        defer { tree.forEach { _ = kill($0.pid, SIGKILL) } }
        do { _ = try await connection.request("exit", timeout: 3); XCTFail("Server exited") }
        catch { XCTAssertTrue(error.localizedDescription.contains("closed its output"), error.localizedDescription) }
        try await assertGone(tree.map(\.pid))
        await connection.stop()
    }
}
