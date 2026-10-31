import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ReconRunAppTests: XCTestCase {
    @MainActor func fixture(scope: [String]) throws -> (URL, WorkbenchModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "recon-eng", objective: "Authorized client test", roles: ["operator"],
                                            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64),
                                            authorizedScope: scope)
        model.session.researchCase = try .init(contract: contract)
        return (root, model)
    }

    @MainActor func testReconOutOfScopeBlocksAndNeverFreezes() throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        // Out-of-scope host must be refused before any plan is frozen for review — even if nmap exists.
        model.prepareReconRun(tool: .nmap, target: "evil.example", extraArgs: ["-sV"])
        XCTAssertFalse(model.showReconConfirmation)
        XCTAssertNil(model.pendingReconPlan)
        XCTAssertNotNil(model.error)
    }

    @MainActor func testReconInScopeFreezesForReview() throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        guard ReconControl.detect(.nmap) != nil else {
            throw XCTSkip("nmap not installed; plan construction needs a real executable.")
        }
        model.prepareReconRun(tool: .nmap, target: "host.client.test", extraArgs: ["-sV", "-Pn"])
        XCTAssertTrue(model.showReconConfirmation)
        XCTAssertNotNil(model.pendingReconPlan)
        XCTAssertEqual(model.pendingReconPlan?.arguments, ["-sV", "-Pn", "host.client.test"])
        XCTAssertEqual(model.pendingReconPlan?.receipt.targets, ["host.client.test"])
        // Reviewing but cancelling runs nothing.
        model.cancelReconRun()
        XCTAssertFalse(model.showReconConfirmation)
        XCTAssertNil(model.pendingReconPlan)
        XCTAssertFalse(model.running)
    }

    @MainActor func testNmapImportPinsServicesAsSourceReportLeads() async throws {
        let (root, model) = try fixture(scope: ["*.client.test"]); defer { try? FileManager.default.removeItem(at: root) }
        let xml = """
        <?xml version="1.0"?>
        <nmaprun scanner="nmap">
          <host>
            <address addr="10.0.0.5" addrtype="ipv4"/>
            <hostnames><hostname name="host.client.test" type="PTR"/></hostnames>
            <ports>
              <port protocol="tcp" portid="22"><state state="open"/><service name="ssh" product="OpenSSH"/></port>
              <port protocol="tcp" portid="8080"><state state="open"/><service name="http-proxy"/></port>
            </ports>
          </host>
        </nmaprun>
        """
        let file = root.appendingPathComponent("scan.xml")
        try Data(xml.utf8).write(to: file)

        model.importNmapResults(resultsPath: file.path)
        let deadline = Date().addingTimeInterval(20)
        while !model.toolStatus.contains("Imported") && model.error == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(model.error, model.error ?? "")

        let evidence = model.session.researchCase!.ledger.evidence
        let leads = evidence.filter { $0.kind == .sourceReport }
        XCTAssertEqual(leads.count, 2)
        XCTAssertTrue(evidence.allSatisfy { $0.kind == .sourceReport }, "nmap services must import as leads, never hostReceipts")

        // A claim citing only an nmap lead cannot promote to a Finding.
        var state = model.session.researchCase!
        let hash = try state.contract.digest()
        let claim = "The SSH service on host.client.test is exploitable."
        try state.ledger.propose(.init(id: "nmap-lead", content: claim, meaning: .reported, evidenceIDs: [leads[0].id]))
        try state.ledger.recordOperatorReview(.init(factID: "nmap-lead", contentHash: ResearchEvidence.hash(claim), evidenceIDs: [leads[0].id], state: .approved, reviewer: "operator"))
        XCTAssertFalse(try FindingVerification.verify(factID: "nmap-lead", ledger: state.ledger, caseID: state.contract.id, contractHash: hash).isFinding,
                       "a scanner lead alone must not satisfy the finding gate")
    }
}
