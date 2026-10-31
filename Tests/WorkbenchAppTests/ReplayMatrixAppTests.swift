import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ReplayMatrixAppTests: XCTestCase {
    private func startFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
import http.server
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  b=(b'{"account":"0001","balance":9999}' if self.headers.get('Authorization','').startswith('Bearer ') else b'denied')
  self.send_response(200 if b!=b'denied' else 401); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True)
for _ in range(10): s.handle_request()
s.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor func testIdentityMatrixCapturesEvidenceAndPromotesFinding() async throws {
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "bola-eng", objective: "Access-control test", roles: ["operator"],
            allowedActions: ["replay"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64),
            authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)

        model.runIdentityMatrix(method: "GET", urlString: "http://127.0.0.1:\(port)/accounts/0001", identities: [
            ReplayIdentity(label: "owner", authorized: true, headers: ["Authorization": "Bearer owner"]),
            ReplayIdentity(label: "attacker", authorized: false, headers: ["Authorization": "Bearer attacker"]),
            ReplayIdentity(label: "anon", authorized: false, headers: [:])
        ])
        let deadline = Date().addingTimeInterval(30)
        while model.replayBusy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(model.replayBusy)
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertTrue(model.toolStatus.contains("brokenAccessControl"), model.toolStatus)

        // Three responses pinned as host evidence.
        let evidence = model.session.researchCase!.ledger.evidence.filter { $0.id.hasPrefix("replay-") && $0.kind == .hostReceipt }
        XCTAssertEqual(evidence.count, 3)
        let owner = evidence.first { $0.id.contains("owner") }!
        let attacker = evidence.first { $0.id.contains("attacker") }!

        // A claim citing the owner + attacker captures promotes to a Finding.
        var state = model.session.researchCase!
        let hash = try state.contract.digest()
        let claim = "Observed: the attacker identity retrieved account 0001's balance byte-identical to the owner (captured responses attached)."
        try state.ledger.propose(.init(id: "bola-finding", content: claim, meaning: .observation, evidenceIDs: [owner.id, attacker.id]))
        try state.ledger.recordOperatorReview(.init(factID: "bola-finding", contentHash: ResearchEvidence.hash(claim), evidenceIDs: [owner.id, attacker.id], state: .approved, reviewer: "operator"))
        let verdict = try FindingVerification.verify(factID: "bola-finding", ledger: state.ledger, caseID: state.contract.id, contractHash: hash)
        XCTAssertTrue(verdict.isFinding, verdict.summary)
    }

    @MainActor func testAuthorizationPersistenceDetectsStaleCredential() async throws {
        // The fixture returns the protected record for any bearer token, both calls — i.e. the
        // backend does NOT re-check authorization, so the credential outlives its revocation.
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "authpersist-eng", objective: "Authorization persistence", roles: ["operator"],
            allowedActions: ["replay"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)
        let url = "http://127.0.0.1:\(port)/accounts/0001"
        let creds = ["Authorization": "Bearer still-valid"]

        model.captureAuthorizationBaseline(method: "GET", urlString: url, label: "session-A", headers: creds, change: "revoke the test user")
        var deadline = Date().addingTimeInterval(20)
        while model.authCheckBusy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(model.pendingAuthBaseline)
        XCTAssertTrue(model.toolStatus.contains("Baseline captured"), model.toolStatus)

        // Operator would revoke here out-of-band. Fixture keeps returning 200 (the vuln).
        model.recheckAuthorizationAfterChange()
        deadline = Date().addingTimeInterval(20)
        while model.authCheckBusy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertTrue(model.toolStatus.contains("STALE AUTHORIZATION"), model.toolStatus)
        XCTAssertNil(model.pendingAuthBaseline)

        let evidence = model.session.researchCase!.ledger.evidence.filter { $0.id.hasPrefix("authchk-") && $0.kind == .hostReceipt }
        XCTAssertEqual(evidence.count, 2)

        // Promote: a claim citing the before + after captures becomes a Finding.
        var state = model.session.researchCase!
        let hash = try state.contract.digest()
        let claim = "Observed: the credential returned account 0001's record byte-identical after the test user was revoked (before/after captures attached)."
        try state.ledger.propose(.init(id: "stale-finding", content: claim, meaning: .observation, evidenceIDs: evidence.map(\.id)))
        try state.ledger.recordOperatorReview(.init(factID: "stale-finding", contentHash: ResearchEvidence.hash(claim), evidenceIDs: evidence.map(\.id), state: .approved, reviewer: "operator"))
        let verdict = try FindingVerification.verify(factID: "stale-finding", ledger: state.ledger, caseID: state.contract.id, contractHash: hash)
        XCTAssertTrue(verdict.isFinding, verdict.summary)
    }
}
