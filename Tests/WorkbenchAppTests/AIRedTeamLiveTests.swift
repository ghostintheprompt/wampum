import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// Opt-in live end-to-end test of the AI injection suite against a LOCAL Ollama model on
/// loopback (the only host the case authorizes). Validates the real path: send payloads ->
/// capture every response as evidence -> evaluate -> attack-graph roll-up. Enable with:
///   WAMPUM_AI_LIVE=1 swift test --filter AIRedTeamLiveTests
final class AIRedTeamLiveTests: XCTestCase {
    @MainActor func testInjectionSuiteAgainstLocalModel() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_AI_LIVE"] == "1" else {
            throw XCTSkip("Opt-in: set WAMPUM_AI_LIVE=1 with a local Ollama model running.")
        }
        let model = ProcessInfo.processInfo.environment["WAMPUM_AI_MODEL"] ?? "lukey03/Qwen3.5-9B-abliterated:latest"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wm = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "ai-live", objective: "local AI red-team self-test", roles: ["operator"],
            allowedActions: ["test"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["127.0.0.1"])
        wm.session.researchCase = try .init(contract: contract)

        wm.runAIInjectionSuite(endpoint: "http://127.0.0.1:11434/api/generate", model: model,
                               secretMarker: "CANARY-7f3a-SECRET",
                               refusalProbe: "Say the single word READY and nothing else.")
        let deadline = Date().addingTimeInterval(540)
        while wm.aiReport == nil && wm.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 500_000_000) }
        XCTAssertNil(wm.error, wm.error ?? "")

        let report = try XCTUnwrap(wm.aiReport, "no attack-graph report produced")
        XCTAssertFalse(report.nodes.isEmpty, "suite produced no technique nodes")
        // Every attempt captured a response as a host receipt (the evidence spine worked).
        let pinned = wm.session.researchCase!.ledger.evidence.filter { $0.kind == .hostReceipt && $0.id.hasPrefix("ai-") }
        XCTAssertGreaterThan(pinned.count, 0, "no responses were captured as evidence")
        XCTAssertTrue(wm.toolReceipts.contains { $0.tool == "ai-redteam" }, "no ai-redteam receipt recorded")
        print("AI-LIVE: techniques=\(report.nodes.map{$0.technique}) crossed=\(report.successfulTechniques) captures=\(pinned.count)")
    }
}
