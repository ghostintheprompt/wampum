import XCTest
@testable import WorkbenchCore

final class RequestReplayerTests: XCTestCase {
    private func startFixture() throws -> (Process, String) {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Vulnerable endpoint: any bearer token returns the same owner record (BOLA); no token = 401.
        server.arguments = ["-u", "-c", """
import http.server
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  auth=self.headers.get('Authorization','')
  if auth.startswith('Bearer '):
   b=b'{"account":"0001","balance":9999}'; self.send_response(200)
  else:
   b=b'denied'; self.send_response(401)
  self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True)
for _ in range(6): s.handle_request()
s.server_close()
"""]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        var bytes = Data(); while !bytes.contains(10) { guard let b = try pipe.fileHandleForReading.read(upToCount: 1), !b.isEmpty else { throw WorkbenchError.invalid("fixture failed") }; bytes.append(b) }
        return (server, String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testReplayCapturesBOLAAndComparisonFlagsIt() async throws {
        let (server, port) = try startFixture(); defer { if server.isRunning { server.terminate() } }
        let url = URL(string: "http://127.0.0.1:\(port)/accounts/0001")!
        let scope = AuthorizedScope(["127.0.0.1"])
        let replayer = RequestReplayer(guardrail: NetworkGuard())
        let identities = [
            ReplayIdentity(label: "owner", authorized: true, headers: ["Authorization": "Bearer owner-token"]),
            ReplayIdentity(label: "attacker", authorized: false, headers: ["Authorization": "Bearer attacker-token"]),
            ReplayIdentity(label: "anonymous", authorized: false, headers: [:])
        ]
        var observations: [ResponseObservation] = []
        for id in identities {
            let r = try await replayer.send(method: "GET", url: url, identity: id, scope: scope)
            observations.append(r.observation)
        }
        // owner 200, attacker 200 (same body → BOLA), anonymous 401
        XCTAssertEqual(observations.first { $0.label == "anonymous" }?.status, 401)
        let signal = try ResponseComparison.evaluate(observations)
        XCTAssertEqual(signal.classification, .brokenAccessControl, signal.detail)
        XCTAssertEqual(signal.unauthorizedLabels, ["attacker"])
    }

    func testOutOfScopeTargetRefusedBeforeSend() async throws {
        let replayer = RequestReplayer(guardrail: NetworkGuard())
        let id = ReplayIdentity(label: "x", authorized: true, headers: [:])
        do {
            _ = try await replayer.send(method: "GET", url: URL(string: "https://not-in-scope.example/")!,
                                        identity: id, scope: AuthorizedScope(["*.allowed.test"]))
            XCTFail("out-of-scope host must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the case's authorized scope"), error.localizedDescription)
        }
    }

    func testEmptyScopeFailsClosed() async throws {
        let replayer = RequestReplayer(guardrail: NetworkGuard())
        let id = ReplayIdentity(label: "x", authorized: true, headers: [:])
        do {
            _ = try await replayer.send(method: "GET", url: URL(string: "https://anything.test/")!, identity: id, scope: AuthorizedScope([]))
            XCTFail("empty scope authorizes nothing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No authorized scope"), error.localizedDescription)
        }
    }
}
