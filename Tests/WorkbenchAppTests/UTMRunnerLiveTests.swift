import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// Opt-in live integration test for the host-side utmctl plumbing. Needs a running UTM guest
/// with the QEMU guest agent. Enable with WAMPUM_UTM_LIVE=1 (optional WAMPUM_UTM_VM, default Kali):
///   WAMPUM_UTM_LIVE=1 swift test --filter UTMRunnerLiveTests
final class UTMRunnerLiveTests: XCTestCase {
    func testGuestExecAndFileRoundTripLive() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_UTM_LIVE"] == "1" else {
            throw XCTSkip("Opt-in: set WAMPUM_UTM_LIVE=1 with a running UTM guest.")
        }
        guard let utmctl = UTMControl.detect() else { throw XCTSkip("utmctl not found.") }
        let vm = ProcessInfo.processInfo.environment["WAMPUM_UTM_VM"] ?? "Kali"
        let runner = UTMRunner(utmctl: utmctl, vm: vm)

        // Warm up / confirm the agent (same as the production capture flow does first).
        let ready = await runner.waitForAgent(maxSeconds: 30)
        XCTAssertTrue(ready, "Guest agent did not respond; is the VM up with qemu-guest-agent?")

        // exec via /bin/bash -lc — retry to absorb utmctl's intermittent empty first response.
        var out = ""
        for _ in 0..<5 { out = (try? await runner.guestBash("echo WAMPUM_LIVE_OK", timeout: 15)) ?? ""; if out.contains("WAMPUM_LIVE_OK") { break } }
        XCTAssertTrue(out.contains("WAMPUM_LIVE_OK"), "exec stdout: '\(out)'")

        // file push → pull round trip returns the exact bytes
        let payload = Data("roundtrip-\(UUID().uuidString)".utf8)
        try await runner.push(payload, to: "/tmp/wampum-rt.txt")
        let back = try await runner.pull("/tmp/wampum-rt.txt")
        XCTAssertEqual(back, payload)
    }
}
