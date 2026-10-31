import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// Opt-in live test of the reviewed recon RUN path end to end: it spawns the REAL nmap binary
/// via the same `prepareReconRun` → `allowReconRun` flow the Tools panel uses, scanning only
/// loopback (127.0.0.1, an authorized in-scope target on this machine), and checks that a real
/// receipt with real output bytes and an exit code comes back. Enable with WAMPUM_RECON_LIVE=1:
///   WAMPUM_RECON_LIVE=1 swift test --filter ReconRunLiveTests
/// This is the live counterpart to the fixture-only ReconRunAppTests; nothing outside loopback
/// is ever touched because the scope gate authorizes 127.0.0.1 and nothing else.
final class ReconRunLiveTests: XCTestCase {
    @MainActor func testNmapAgainstLoopbackProducesRealReceipt() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_RECON_LIVE"] == "1" else {
            throw XCTSkip("Opt-in: set WAMPUM_RECON_LIVE=1 to run real nmap against loopback.")
        }
        guard ReconControl.detect(.nmap) != nil else { throw XCTSkip("nmap not installed.") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        // Only loopback is in scope — the gate authorizes 127.0.0.1 and refuses everything else.
        let contract = ResearchCaseContract(id: "recon-live", objective: "Loopback recon self-test", roles: ["operator"],
            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)

        // A tiny, fast, unprivileged scan of two ports on our own loopback.
        model.prepareReconRun(tool: .nmap, target: "127.0.0.1", extraArgs: ["-p", "22,80", "-Pn", "-T4"])
        XCTAssertTrue(model.showReconConfirmation, model.error ?? "plan was not frozen for review")
        XCTAssertNotNil(model.pendingReconPlan)

        model.allowReconRun()   // operator approves — nmap actually runs here
        let deadline = Date().addingTimeInterval(60)
        while model.running && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(model.running, "nmap did not finish within the timeout")

        let receipt = model.toolReceipts.last { $0.tool == "nmap" }
        XCTAssertNotNil(receipt, "no nmap receipt recorded")
        XCTAssertEqual(receipt?.outcome, .succeeded, receipt?.detail ?? "")
        XCTAssertEqual(receipt?.targets, ["127.0.0.1"])
        XCTAssertNotNil(receipt?.resultSHA256, "the receipt should hash the captured output")
        // The real nmap banner should be in the captured output.
        XCTAssertTrue(model.output.contains("Nmap") || model.output.contains("nmap"), "captured output: \(model.output.prefix(200))")
    }

    /// Seeds an isolated state dir with a loopback-only case so the GUI app, launched with
    /// WAMPUM_STATE_DIR pointed at it, opens straight into a scoped engagement — used to drive
    /// the real app window without hand-importing a contract. Opt-in: set WAMPUM_SEED_STATE_DIR.
    @MainActor func testSeedLoopbackCaseIntoStateDir() throws {
        guard let dir = ProcessInfo.processInfo.environment["WAMPUM_SEED_STATE_DIR"] else {
            throw XCTSkip("Opt-in: set WAMPUM_SEED_STATE_DIR to seed a loopback case for GUI driving.")
        }
        let root = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root)
        let contract = ResearchCaseContract(id: "loopback-selftest", objective: "Scope-gated loopback recon self-test", roles: ["operator"],
            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        model.session.researchCase = try .init(contract: contract)
        model.persist()
        XCTAssertNil(model.error, model.error ?? "")

        // Reload through a fresh model from the same dir — exactly what the GUI does on launch.
        let reloaded = WorkbenchModel(stateDirectory: root)
        XCTAssertNil(reloaded.error, reloaded.error ?? "")
        XCTAssertEqual(reloaded.session.researchCase?.contract.id, "loopback-selftest", "seeded case did not round-trip")
        XCTAssertEqual(reloaded.session.researchCase?.contract.authorizedScope, ["127.0.0.1"])

        // And through the ENV path (no stateDirectory arg) — exactly WorkbenchModel() in the app,
        // only meaningful when WAMPUM_STATE_DIR is this same dir.
        if ProcessInfo.processInfo.environment["WAMPUM_STATE_DIR"] == dir {
            let viaEnv = WorkbenchModel()
            XCTAssertEqual(viaEnv.session.researchCase?.contract.id, "loopback-selftest", "env-path load dropped the case")
        }
    }
}
