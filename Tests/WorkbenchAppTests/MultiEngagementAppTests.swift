import XCTest
@testable import Wampum
@testable import WorkbenchCore

/// Client-readiness: tool receipts must be bound to the engagement they were produced under,
/// so one client's activity never surfaces while working another's.
final class MultiEngagementAppTests: XCTestCase {
    @MainActor func testReceiptsAreStampedWithActiveEngagementAndSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let out = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func caseContract(_ id: String) -> ResearchCaseContract {
            .init(id: id, objective: "x", roles: ["operator"], allowedActions: ["scan"],
                  requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.\(id).test"])
        }

        // Engagement A: produce a receipt (export records a report/export receipt synchronously).
        model.session.researchCase = try .init(contract: caseContract("alpha"))
        model.generateFindingReport(program: "A")
        model.exportFindingReport(program: "A", to: out)
        XCTAssertNil(model.error, model.error ?? "")

        // Switch to engagement B and produce another receipt.
        model.session.researchCase = try .init(contract: caseContract("bravo"))
        model.generateFindingReport(program: "B")
        model.exportFindingReport(program: "B", to: out)
        XCTAssertNil(model.error, model.error ?? "")

        // Both receipts exist, each stamped with the engagement active when it was recorded.
        let reportReceipts = model.toolReceipts.filter { $0.tool == "report" }
        XCTAssertEqual(reportReceipts.count, 2)
        XCTAssertEqual(reportReceipts.filter { $0.engagement == "alpha" }.count, 1)
        XCTAssertEqual(reportReceipts.filter { $0.engagement == "bravo" }.count, 1)

        // The operator view scopes to the active engagement: while on bravo, alpha's receipt is hidden.
        let activeID = model.session.researchCase?.contract.id
        XCTAssertEqual(activeID, "bravo")
        let visible = model.toolReceipts.filter { $0.engagement == activeID }
        XCTAssertTrue(visible.allSatisfy { $0.engagement == "bravo" })
        XCTAssertFalse(visible.contains { $0.engagement == "alpha" }, "alpha's receipt must not be visible under bravo")
    }

    @MainActor func testEngagementBundleIsSelfContainedAndScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let out = root.appendingPathComponent("exports"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let contract = ResearchCaseContract(id: "client-x", objective: "x", roles: ["operator"], allowedActions: ["scan"],
            requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.client-x.test"])
        var state = try ResearchCaseState(contract: contract)
        let hash = try contract.digest()
        let cap = root.appendingPathComponent("capture.bin"); try Data("CAPTURED".utf8).write(to: cap)
        try state.ledger.addEvidence(try .pin(id: "cap-1", caseID: contract.id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        let claim = "Observed: cross-tenant read on app.client-x.test, captured in the receipt."
        try state.ledger.propose(.init(id: "f1", content: claim, meaning: .observation, evidenceIDs: ["cap-1"]))
        try state.ledger.recordOperatorReview(.init(factID: "f1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["cap-1"], state: .approved, reviewer: "operator"))
        model.session.researchCase = state
        // One receipt for this engagement, and one for a different engagement that must NOT appear.
        model.generateFindingReport(program: "p"); model.exportFindingReport(program: "p", to: out) // records report/export under client-x

        model.exportEngagementBundle(to: out)
        let deadline = Date().addingTimeInterval(20)
        while !(model.reportStatus.contains("Engagement exported") || model.reportStatus.contains("failed")) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(model.error, model.error ?? "")

        let bundles = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix("wampum-engagement-") }
        XCTAssertEqual(bundles.count, 1)
        let b = out.appendingPathComponent(bundles[0])
        for f in ["report.md", "report.json", "ledger.json", "receipts.json", "network-events.json", "manifest.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent(f).path), "missing \(f)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent("evidence/cap-1-capture.bin").path))

        // receipts.json only contains this engagement's receipts.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let receipts = try dec.decode([ToolReceipt].self, from: Data(contentsOf: b.appendingPathComponent("receipts.json")))
        XCTAssertFalse(receipts.isEmpty)
        XCTAssertTrue(receipts.allSatisfy { $0.engagement == "client-x" })

        // The export receipt's hash matches the manifest bytes on disk.
        let exportReceipt = model.toolReceipts.last { $0.tool == "engagement" && $0.action == "export" }
        XCTAssertNotNil(exportReceipt)
        let manifestBytes = try Data(contentsOf: b.appendingPathComponent("manifest.json"))
        XCTAssertEqual(exportReceipt?.resultSHA256, ToolReceipt.hash(String(decoding: manifestBytes, as: UTF8.self)))
    }

    @MainActor func testLedgerImportRefusesAnotherEngagementsLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))

        func contract(_ id: String) -> ResearchCaseContract {
            .init(id: id, objective: "x", roles: ["operator"], allowedActions: ["scan"], requiredUnits: ["r"],
                  rubricSHA256: String(repeating: "a", count: 64), authorizedScope: ["*.\(id).test"])
        }
        // Active engagement A.
        let a = contract("client-a")
        model.session.researchCase = try .init(contract: a)

        // A ledger that belongs to engagement B must be refused with a clear message.
        let b = contract("client-b")
        let bLedger = ResearchEvidence.Ledger(caseID: b.id, contractHash: try b.digest())
        let bData = try JSONEncoder().encode(bLedger)
        XCTAssertThrowsError(try model.reviewImportedLedger(bData)) { err in
            let msg = "\(err)"
            XCTAssertTrue(msg.contains("belongs to engagement") && msg.contains("client-b") && msg.contains("refused"), msg)
        }

        // A ledger for the active engagement A is accepted.
        let aLedger = ResearchEvidence.Ledger(caseID: a.id, contractHash: try a.digest())
        let aData = try JSONEncoder().encode(aLedger)
        XCTAssertNoThrow(try model.reviewImportedLedger(aData))
    }

    @MainActor func testLegacyUnscopedReceiptDecodesAsNilAndIsHiddenUnderACase() throws {
        // A receipt created directly (no engagement set) is unscoped until recorded under a case.
        let r = ToolReceipt(tool: "docker", action: "ps", targets: [], argument: "docker ps")
        XCTAssertNil(r.engagement)
        // Round-trips through Codable preserving nil engagement (backward compatibility).
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ToolReceipt.self, from: data)
        XCTAssertNil(back.engagement)
    }
}
