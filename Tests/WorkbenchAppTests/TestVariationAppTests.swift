import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// End-to-end test of the detection-variation runner against a loopback fixture that reacts
/// differently depending on the request (a stand-in for a defense that distinguishes inputs).
/// Loopback only; the scope gate authorizes 127.0.0.1 and refuses anything else.
final class TestVariationAppTests: XCTestCase {
    private func startFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Returns 403 when the User-Agent contains "bot", else 200 — a toy "defense" that
        // distinguishes the recorded variation from the baseline.
        server.arguments = ["-u", "-c", """
import http.server
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  ua=self.headers.get('User-Agent','')
  if 'bot' in ua.lower():
   self.send_response(403); self.end_headers(); self.wfile.write(b'request blocked')
  else:
   self.send_response(200); self.end_headers(); self.wfile.write(b'ok normal response')
 def log_message(self,*a): pass
import http.server as s
srv=s.HTTPServer(('127.0.0.1',0),H); print(srv.server_port,flush=True)
for _ in range(10): srv.handle_request()
srv.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor func testDetectionDifferentialCapturedAndPinned() async throws {
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "variation-eng", objective: "detection test", roles: ["operator"],
            allowedActions: ["test"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)

        let url = "http://127.0.0.1:\(port)/resource"
        let baseline = RequestVariation(label: "baseline", note: "unmodified request")
        let botVariant = RequestVariation(label: "ua-bot", headerOverrides: ["User-Agent": "test-bot/1.0"], note: "rotate UA to a bot string")
        model.runTestVariations(method: "GET", urlString: url, baseline: baseline, variations: [botVariant])

        let deadline = Date().addingTimeInterval(20)
        while model.variationSignal == nil && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(model.error, model.error ?? "")

        let signal = try XCTUnwrap(model.variationSignal)
        XCTAssertEqual(signal.baselineReaction, .allowed)
        XCTAssertTrue(signal.detectionObserved, "the defense distinguished the bot variation")
        XCTAssertEqual(signal.differingVariations, ["ua-bot"])
        XCTAssertEqual(signal.reactions["ua-bot"], "blocked")

        // Both responses were captured and pinned as host receipts (promotable via the finding gate).
        let pinned = model.session.researchCase!.ledger.evidence.filter { $0.kind == .hostReceipt && $0.id.hasPrefix("var-") }
        XCTAssertEqual(pinned.count, 2)
        XCTAssertTrue(model.toolReceipts.contains { $0.tool == "variation" && $0.engagement == "variation-eng" })
    }

    // A fixture that blocks the bot UA on the first run, then stops blocking — simulating a
    // detection regression between two runs of the same saved profile.
    private func startRegressionFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
import http.server
count=0
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  global count; count+=1
  bot='bot' in self.headers.get('User-Agent','').lower()
  # requests 1-2 = run 1 (block bot); requests 3+ = run 2 (bot no longer blocked)
  if count<=2 and bot:
   self.send_response(403); self.end_headers(); self.wfile.write(b'request blocked')
  else:
   self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
 def log_message(self,*a): pass
import http.server as s
srv=s.HTTPServer(('127.0.0.1',0),H); print(srv.server_port,flush=True)
for _ in range(8): srv.handle_request()
srv.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor func testProfileReRunDetectsRegression() async throws {
        let (server, port) = try startRegressionFixture(); defer { if server.isRunning { server.terminate() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "regr-eng", objective: "detection regression", roles: ["operator"],
            allowedActions: ["test"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)

        let url = "http://127.0.0.1:\(port)/resource"
        let baseline = RequestVariation(label: "baseline")
        let bot = RequestVariation(label: "ua-bot", headerOverrides: ["User-Agent": "test-bot/1.0"])

        // Run 1: bot is blocked. No prior → no comparison.
        model.runTestVariations(method: "GET", urlString: url, baseline: baseline, variations: [bot], profileName: "waf-coverage", environment: "prod")
        var deadline = Date().addingTimeInterval(20)
        while model.variationSignal == nil && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 80_000_000) }
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertNil(model.detectionComparison, "first run has no prior to compare")
        XCTAssertEqual(model.variationSignal?.reactions["ua-bot"], "blocked")

        // Run 2 (same profile, same env): bot no longer blocked → regression.
        model.variationSignal = nil
        model.runTestVariations(method: "GET", urlString: url, baseline: baseline, variations: [bot], profileName: "waf-coverage", environment: "prod")
        deadline = Date().addingTimeInterval(20)
        while model.detectionComparison == nil && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 80_000_000) }
        XCTAssertNil(model.error, model.error ?? "")
        let cmp = try XCTUnwrap(model.detectionComparison)
        XCTAssertTrue(cmp.sameEnvironment)
        XCTAssertEqual(cmp.kind, "regression/drift")
        XCTAssertEqual(cmp.changes.first?.label, "ua-bot")
        XCTAssertEqual(cmp.changes.first?.from, "blocked")
        XCTAssertEqual(cmp.changes.first?.to, "allowed")
    }
}
