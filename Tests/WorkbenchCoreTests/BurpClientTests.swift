import XCTest
@testable import WorkbenchCore

final class BurpClientTests: XCTestCase {
    private let scope = AuthorizedScope(["*.target.test"])

    func testRejectsNonLoopbackBaseAndBadKey() {
        XCTAssertThrowsError(try BurpClient(base: URL(string: "http://10.0.0.5:1337")!))
        XCTAssertThrowsError(try BurpClient(base: URL(string: "http://127.0.0.1:1337")!, apiKey: "has/slash"))
        XCTAssertNoThrow(try BurpClient(base: URL(string: "http://127.0.0.1:1337")!, apiKey: "ABC123"))
    }

    func testOutOfScopeTargetFailsBeforeAnyNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let guardrail = NetworkGuard(directory: directory)
        // Port 1 is not listening; if scope gating did not short-circuit, this would error on connect instead.
        let client = try BurpClient(base: URL(string: "http://127.0.0.1:1")!, guardrail: guardrail)
        do {
            _ = try await client.startScan(urls: ["https://app.target.test/", "https://evil.example/"], scope: scope)
            XCTFail("Out-of-scope target must block the whole scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the case's authorized scope"), error.localizedDescription)
        }
        // No PROXY/scan network attempt should have been recorded for an out-of-scope block.
        let records = try await guardrail.recent()
        XCTAssertFalse(records.contains { $0.detail.contains("start scan") })
    }

    func testOutOfBandClassification() {
        func issue(_ name: String) -> BurpClient.BurpIssue { .init(name: name, severity: "high", confidence: "certain", origin: "https://x.test", path: nil) }
        XCTAssertTrue(issue("External service interaction (DNS)").isOutOfBand)
        XCTAssertTrue(issue("Out-of-band resource load (HTTP)").isOutOfBand)
        XCTAssertTrue(issue("Blind SSRF via Collaborator").isOutOfBand)
        XCTAssertFalse(issue("Cross-site scripting (reflected)").isOutOfBand)
        XCTAssertFalse(issue("SQL injection").isOutOfBand)
    }

    func testScanIssuesFixtureFiltersToScope() async throws {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
import http.server, json
BODY=json.dumps({"scan_status":"succeeded","issue_events":[
 {"issue":{"name":"SQL injection","severity":"high","confidence":"certain","origin":"https://app.target.test","path":"/x"}},
 {"issue":{"name":"XSS","severity":"medium","confidence":"firm","origin":"https://evil.example","path":"/y"}}]}).encode()
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(BODY)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.handle_request(); s.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        let port = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try BurpClient(base: URL(string: "http://127.0.0.1:\(port)")!, guardrail: NetworkGuard())
        let issues = try await client.scanIssues(taskID: "1", scope: scope)   // scope = *.target.test
        XCTAssertEqual(issues.count, 1, "only the in-scope issue should import")
        XCTAssertEqual(issues.first?.name, "SQL injection")
        XCTAssertEqual(issues.first?.origin, "https://app.target.test")
    }

    func testStartScanAgainstLoopbackFixtureReturnsTask() async throws {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
import http.server
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
  self.send_response(201); self.send_header('Location','/v0.1/scan/42'); self.end_headers()
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"scan_status":"running"}')
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True)
s.handle_request(); s.handle_request(); s.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        var bytes = Data()
        while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("Burp fixture failed") }; bytes.append(b) }
        let port = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try BurpClient(base: URL(string: "http://127.0.0.1:\(port)")!, guardrail: NetworkGuard(directory: directory))
        let receipt = try await client.startScan(urls: ["https://app.target.test/login"], scope: scope)
        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(receipt.targets, ["app.target.test"])
        XCTAssertTrue(receipt.detail.contains("42"), receipt.detail)

        let status = try await client.scanStatus(taskID: "42")
        XCTAssertEqual(status.summary, "running")
    }
}
