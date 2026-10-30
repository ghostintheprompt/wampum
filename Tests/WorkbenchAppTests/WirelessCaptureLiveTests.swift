import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// Opt-in end-to-end live test of the whole `runWirelessCapture` orchestration against a
/// real UTM guest and an authorized network. Nothing here is committed about any specific
/// network — the authorized BSSID/channel come from the environment:
///
///   WAMPUM_WIFI_LIVE=1 WAMPUM_WIFI_BSSID=AA:BB:CC:DD:EE:FF WAMPUM_WIFI_CHANNEL=6 \
///   WAMPUM_WIFI_ESSID=MyNet WAMPUM_UTM_VM=Kali \
///   swift test --filter WirelessCaptureLiveTests
///
/// Only run this against a network you are authorized to capture.
final class WirelessCaptureLiveTests: XCTestCase {
    @MainActor func testFullCaptureOrchestrationPinsEvidenceLive() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WAMPUM_WIFI_LIVE"] == "1", let bssid = env["WAMPUM_WIFI_BSSID"] else {
            throw XCTSkip("Opt-in: set WAMPUM_WIFI_LIVE=1 and WAMPUM_WIFI_BSSID (authorized network only).")
        }
        guard UTMControl.detect() != nil else { throw XCTSkip("utmctl not found.") }
        let channel = Int(env["WAMPUM_WIFI_CHANNEL"] ?? "6") ?? 6

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))

        let target = WirelessTarget(bssid: bssid, channel: channel, essid: env["WAMPUM_WIFI_ESSID"])
        let contract = ResearchCaseContract(id: "wifi-live-\(Int(Date().timeIntervalSince1970))",
            objective: "Authorized wireless capture", roles: ["operator"], allowedActions: ["capture"],
            requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), wirelessScope: [target])
        model.session.researchCase = try .init(contract: contract)

        model.wirelessVM = env["WAMPUM_UTM_VM"] ?? "Kali"
        model.wirelessAuthorization = "Opt-in live test against an operator-authorized network."
        model.captureDuration = Int(env["WAMPUM_WIFI_DURATION"] ?? "15") ?? 15

        model.runWirelessCapture()
        XCTAssertTrue(model.wirelessBusy)

        // Wait for the detached orchestration to finish (bounded).
        let deadline = Date().addingTimeInterval(300)
        while model.wirelessBusy && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000_000) }
        XCTAssertFalse(model.wirelessBusy, "capture did not finish in time")
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertTrue(model.wirelessStatus.contains("complete"), model.wirelessStatus)

        // A capture must have been pinned as host evidence.
        let evidence = model.session.researchCase!.ledger.evidence
        XCTAssertTrue(evidence.contains { $0.kind == .hostReceipt && $0.id.hasPrefix("wifi-") }, "no wireless hostReceipt pinned")
        XCTAssertTrue(model.toolReceipts.contains { $0.tool == "wireless" && $0.outcome == .succeeded })

        // And that pinned pcap can back a Finding once the operator approves the claim.
        var state = model.session.researchCase!
        let pin = evidence.first { $0.kind == .hostReceipt && $0.id.hasPrefix("wifi-") && $0.path.hasSuffix(".cap") }!
        let hash = try state.contract.digest()
        let claim = "Observed: captured 802.11 frames for the authorized BSSID \(bssid) (see pinned pcap)."
        try state.ledger.propose(.init(id: "wifi-finding", content: claim, meaning: .observation, evidenceIDs: [pin.id]))
        try state.ledger.recordOperatorReview(.init(factID: "wifi-finding", contentHash: ResearchEvidence.hash(claim), evidenceIDs: [pin.id], state: .approved, reviewer: "operator"))
        let verdict = try FindingVerification.verify(factID: "wifi-finding", ledger: state.ledger, caseID: state.contract.id, contractHash: hash)
        XCTAssertTrue(verdict.isFinding, verdict.summary)
    }
}
