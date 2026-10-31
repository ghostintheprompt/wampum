import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ReportAppTests: XCTestCase {
    /// A model with a case plus one approved, host-receipt-backed finding and one bare hypothesis.
    @MainActor func fixtureWithFinding() throws -> (URL, WorkbenchModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "report-eng", objective: "Report", roles: ["operator"],
            allowedActions: ["scan"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.client.test"])
        var state = try ResearchCaseState(contract: contract)
        let hash = try contract.digest()
        let cap = root.appendingPathComponent("capture.jpg")
        try Data("CAPTURED CROSS-TENANT BYTES".utf8).write(to: cap)
        try state.ledger.addEvidence(try .pin(id: "cap-1", caseID: contract.id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        let claim = "Observed: the export endpoint returned account 0002's records for the attacker session, captured in the receipt."
        try state.ledger.propose(.init(id: "finding-good", content: claim, meaning: .observation, evidenceIDs: ["cap-1"]))
        try state.ledger.recordOperatorReview(.init(factID: "finding-good", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["cap-1"], state: .approved, reviewer: "operator"))
        try state.ledger.propose(.init(id: "hyp-open", content: "Possible IDOR on invoices.", meaning: .inference, evidenceIDs: ["cap-1"]))
        model.session.researchCase = state
        return (root, model)
    }

    @MainActor func testGenerateReportPromotesOnlyApprovedBackedClaim() throws {
        let (root, model) = try fixtureWithFinding(); defer { try? FileManager.default.removeItem(at: root) }
        model.generateFindingReport(program: "HackerOne: acme")
        XCTAssertNil(model.error, model.error ?? "")
        XCTAssertEqual(model.findingReport?.findings.count, 1)
        XCTAssertEqual(model.findingReport?.findings.first?.factID, "finding-good")
        XCTAssertEqual(model.findingReport?.excluded.count, 1)
    }

    @MainActor func testExportWritesBundleAndProvesItByReadback() throws {
        let (root, model) = try fixtureWithFinding(); defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        model.generateFindingReport(program: "HackerOne: acme")
        model.exportFindingReport(program: "HackerOne: acme", to: out)
        XCTAssertNil(model.error, model.error ?? "")

        let bundles = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix("wampum-report-") }
        XCTAssertEqual(bundles.count, 1)
        let bundle = out.appendingPathComponent(bundles[0])
        let mdURL = bundle.appendingPathComponent("report.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("report.json").path))
        // The verified receipt was copied into the bundle.
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("evidence/cap-1-capture.jpg").path))

        // The export receipt's hash matches the bytes actually on disk — export is proven, not assumed.
        let exportReceipt = model.toolReceipts.last { $0.tool == "report" && $0.action == "export" }
        XCTAssertNotNil(exportReceipt)
        let onDisk = try Data(contentsOf: mdURL)
        XCTAssertEqual(exportReceipt?.resultSHA256, ToolReceipt.hash(String(decoding: onDisk, as: UTF8.self)))
    }

    @MainActor func testEmptyLedgerExportsNoFindingsNoCrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "empty-eng", objective: "x", roles: ["operator"],
            allowedActions: ["scan"], requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.client.test"])
        model.session.researchCase = try .init(contract: contract)
        model.generateFindingReport(program: "")
        XCTAssertEqual(model.findingReport?.findings.count, 0)
        XCTAssertTrue(model.findingReport?.markdown.contains("No promoted findings") ?? false)
    }
}
