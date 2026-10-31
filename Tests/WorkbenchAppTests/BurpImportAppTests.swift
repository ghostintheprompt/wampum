import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class BurpImportAppTests: XCTestCase {
    private func startFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // One OOB/Collaborator issue and one pattern-match scanner issue, both in scope.
        server.arguments = ["-u", "-c", """
import http.server, json
BODY=json.dumps({"scan_status":"succeeded","issue_events":[
 {"issue":{"name":"External service interaction (DNS)","severity":"high","confidence":"certain","origin":"https://app.client.test","path":"/import"}},
 {"issue":{"name":"Cross-site scripting (reflected)","severity":"medium","confidence":"firm","origin":"https://app.client.test","path":"/search"}}]}).encode()
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(BODY)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True)
for _ in range(4): s.handle_request()
s.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor func testOOBImportsAsPromotableWhileScannerIsLead() async throws {
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "burp-eng", objective: "Import test", roles: ["operator"],
            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.client.test"])
        model.session.researchCase = try .init(contract: contract)
        model.burpBase = "http://127.0.0.1:\(port)"

        model.importBurpIssues(taskID: "7")
        let deadline = Date().addingTimeInterval(20)
        while !model.toolStatus.contains("Imported") && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(model.error, model.error ?? "")

        let evidence = model.session.researchCase!.ledger.evidence
        let oob = evidence.first { $0.kind == .hostReceipt }
        let lead = evidence.first { $0.kind == .sourceReport }
        XCTAssertNotNil(oob, "the OOB interaction should import as a hostReceipt")
        XCTAssertNotNil(lead, "the scanner issue should import as a sourceReport lead")

        var state = model.session.researchCase!
        let hash = try state.contract.digest()
        // A claim citing the OOB interaction promotes.
        let oobClaim = "Observed: the target performed an out-of-band DNS interaction triggered by the payload (Burp-observed, pinned)."
        try state.ledger.propose(.init(id: "oob-finding", content: oobClaim, meaning: .observation, evidenceIDs: [oob!.id]))
        try state.ledger.recordOperatorReview(.init(factID: "oob-finding", contentHash: ResearchEvidence.hash(oobClaim), evidenceIDs: [oob!.id], state: .approved, reviewer: "operator"))
        XCTAssertTrue(try FindingVerification.verify(factID: "oob-finding", ledger: state.ledger, caseID: state.contract.id, contractHash: hash).isFinding)

        // A claim citing only the scanner lead cannot promote.
        let leadClaim = "The search parameter is vulnerable per the scanner."
        try state.ledger.propose(.init(id: "lead-finding", content: leadClaim, meaning: .reported, evidenceIDs: [lead!.id]))
        try state.ledger.recordOperatorReview(.init(factID: "lead-finding", contentHash: ResearchEvidence.hash(leadClaim), evidenceIDs: [lead!.id], state: .approved, reviewer: "operator"))
        XCTAssertFalse(try FindingVerification.verify(factID: "lead-finding", ledger: state.ledger, caseID: state.contract.id, contractHash: hash).isFinding)
    }
}
