import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// End-to-end BOLA sweep against a deliberately-vulnerable loopback fixture that serves any
/// object to anyone (no per-object authorization). Loopback only; scope authorizes 127.0.0.1.
final class BolaSweepAppTests: XCTestCase {
    private func startFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Returns deterministic per-id content regardless of identity — classic BOLA.
        server.arguments = ["-u", "-c", """
import http.server
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  oid=self.path.rstrip('/').split('/')[-1]
  self.send_response(200); self.end_headers(); self.wfile.write(('data-for-%s'%oid).encode())
 def log_message(self,*a): pass
import http.server as s
srv=s.HTTPServer(('127.0.0.1',0),H); print(srv.server_port,flush=True)
for _ in range(12): srv.handle_request()
srv.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor func testCrossTenantReadsCapturedAndPinned() async throws {
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "bola-eng", objective: "idor test", roles: ["operator"],
            allowedActions: ["test"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)

        let tmpl = "http://127.0.0.1:\(port)/obj/{id}"
        let identities = [
            BolaIdentity(label: "owner-0001", ownedObjectIDs: ["0001"], headers: ["Authorization": "Bearer OWNER1"]),
            BolaIdentity(label: "attacker", ownedObjectIDs: [], headers: ["Authorization": "Bearer ATTACKER"]),
        ]
        model.runBolaSweep(method: "GET", urlTemplate: tmpl, objectIDs: ["0001", "0002"], identities: identities)

        let deadline = Date().addingTimeInterval(20)
        while model.bolaSignal == nil && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 80_000_000) }
        XCTAssertNil(model.error, model.error ?? "")

        let s = try XCTUnwrap(model.bolaSignal)
        XCTAssertTrue(s.present)
        // attacker read 0001, and it was byte-identical to what owner-0001 received.
        let attacker0001 = s.crossTenant.first { $0.identity == "attacker" && $0.objectID == "0001" }
        XCTAssertNotNil(attacker0001)
        XCTAssertTrue(attacker0001?.byteIdenticalToOwner ?? false)

        // All 4 responses pinned as host receipts; one bola receipt stamped with the engagement.
        let pinned = model.session.researchCase!.ledger.evidence.filter { $0.kind == .hostReceipt && $0.id.hasPrefix("bola-") }
        XCTAssertEqual(pinned.count, 4)
        XCTAssertTrue(model.toolReceipts.contains { $0.tool == "bola" && $0.engagement == "bola-eng" })
    }
}
