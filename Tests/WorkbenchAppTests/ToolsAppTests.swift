import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ToolsAppTests: XCTestCase {
    @MainActor func fixture(scope: [String]) throws -> (URL, WorkbenchModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "engagement", objective: "Authorized client test", roles: ["operator"],
                                            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64),
                                            authorizedScope: scope)
        model.session.researchCase = try .init(contract: contract)
        return (root, model)
    }

    @MainActor func testBurpScanOutOfScopeIsBlockedAndRecordsNoTask() async throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        model.burpScan(urls: ["https://app.client.test/", "https://not-the-client.example/"])
        // Let the async task settle.
        for _ in 0..<50 where model.error == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.error!.contains("outside the case's authorized scope"), model.error ?? "")
        XCTAssertTrue(model.toolReceipts.filter { $0.tool == "burp" && $0.outcome == .succeeded }.isEmpty)
    }

    @MainActor func testDockerNetworkActionNeedsInScopeTargetAndFreezesForReview() throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        // No declared target for a network-capable subcommand → blocked, nothing frozen.
        model.prepareDockerRun(subcommand: "run", arguments: ["scanner:latest"], targets: [])
        XCTAssertFalse(model.showDockerConfirmation)
        XCTAssertNotNil(model.error)
        // Out-of-scope target → blocked.
        model.error = nil
        model.prepareDockerRun(subcommand: "run", arguments: ["scanner:latest"], targets: ["https://evil.example/"])
        XCTAssertFalse(model.showDockerConfirmation)
        XCTAssertNotNil(model.error)
        // In-scope target → frozen for explicit review, still not run.
        model.error = nil
        guard DockerControl.detect() != nil else {
            throw XCTSkip("Docker CLI not installed; plan construction needs a real executable.")
        }
        model.prepareDockerRun(subcommand: "ps", arguments: ["-a"], targets: [])
        XCTAssertTrue(model.showDockerConfirmation)
        XCTAssertNotNil(model.pendingDockerPlan)
        XCTAssertEqual(model.pendingDockerPlan?.arguments, ["ps", "-a"])
        model.cancelDockerRun()
        XCTAssertFalse(model.showDockerConfirmation)
        XCTAssertNil(model.pendingDockerPlan)
    }

    @MainActor func testToolReceiptPinsIntoLedgerAsHostEvidence() throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        let receipt = ToolReceipt(tool: "burp", action: "scan", targets: ["app.client.test"], argument: "{\"urls\":[\"https://app.client.test/\"]}", outcome: .succeeded, detail: "Scan task 7 accepted.")
        let before = model.session.researchCase!.ledger.evidence.count
        model.pinToolReceiptAsEvidence(receipt)
        XCTAssertNil(model.error, model.error ?? "")
        let evidence = model.session.researchCase!.ledger.evidence
        XCTAssertEqual(evidence.count, before + 1)
        XCTAssertEqual(evidence.last?.kind, .hostReceipt)
        XCTAssertEqual(evidence.last?.id, "tool-" + receipt.id.uuidString)

        // The pinned receipt can now back a Finding once the operator approves the claim.
        var state = model.session.researchCase!
        let hash = try state.contract.digest()
        let claim = "Observed: the scan receipt records a confirmed cross-tenant read on app.client.test."
        try state.ledger.propose(.init(id: "finding-1", content: claim, meaning: .observation, evidenceIDs: [evidence.last!.id]))
        var hypothesis = try FindingVerification.verify(factID: "finding-1", ledger: state.ledger, caseID: state.contract.id, contractHash: hash)
        XCTAssertFalse(hypothesis.isFinding) // not approved yet
        try state.ledger.recordOperatorReview(.init(factID: "finding-1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: [evidence.last!.id], state: .approved, reviewer: "operator"))
        let finding = try FindingVerification.verify(factID: "finding-1", ledger: state.ledger, caseID: state.contract.id, contractHash: hash)
        XCTAssertTrue(finding.isFinding, finding.summary)
        _ = hypothesis
    }
}
