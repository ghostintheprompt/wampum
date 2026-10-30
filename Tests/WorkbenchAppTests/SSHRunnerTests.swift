import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class SSHRunnerTests: XCTestCase {
    func testPathQuotingEscapesSingleQuotes() {
        XCTAssertEqual(SSHRunner.quote("/tmp/x.json"), "'/tmp/x.json'")
        // A single quote in the path is escaped safely.
        XCTAssertEqual(SSHRunner.quote("/tmp/a'b"), "'/tmp/a'\\''b'")
    }

    func testPushPullRejectUnsafeGuestPaths() async {
        let r = SSHRunner(host: "127.0.0.1", port: 22, user: "kali", identity: nil)
        do { try await r.push(Data("x".utf8), to: "relative/path"); XCTFail("should reject") } catch {}
        do { _ = try await r.pull("/tmp/../etc/shadow"); XCTFail("should reject") } catch {}
    }

    func testUTMRunnerAndSSHRunnerBothConformToTransport() {
        // Compile-time: both can be used polymorphically as the capture transport.
        let utm: GuestTransport = UTMRunner(utmctl: URL(fileURLWithPath: "/bin/echo"), vm: "Kali")
        let ssh: GuestTransport = SSHRunner(host: "h", port: 2222, user: "u", identity: nil)
        XCTAssertNotNil(utm); XCTAssertNotNil(ssh)
    }
}
