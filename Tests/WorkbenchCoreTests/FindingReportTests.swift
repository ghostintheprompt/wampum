import XCTest
@testable import WorkbenchCore

final class FindingReportTests: XCTestCase {
    private func contract() -> ResearchCaseContract {
        .init(id: "bounty-report", objective: "Report the access-control claim", roles: ["operator"],
              allowedActions: ["Review captured evidence"], requiredUnits: ["analysis"], rubricSHA256: String(repeating: "a", count: 64))
    }

    /// A ledger with one approved, host-backed finding plus one unapproved hypothesis.
    private func populatedLedger(root: URL) throws -> (ResearchEvidence.Ledger, String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)

        let cap = root.appendingPathComponent("capture.jpg")
        try Data("CAPTURED CROSS-TENANT RESPONSE BYTES".utf8).write(to: cap)
        try ledger.addEvidence(try .pin(id: "cap-1", caseID: contract().id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        let good = "Observed: the export endpoint returned account 0002's records for the attacker session, captured in the receipt."
        try ledger.propose(.init(id: "finding-good", content: good, meaning: .observation, evidenceIDs: ["cap-1"]))
        try ledger.recordOperatorReview(.init(factID: "finding-good", contentHash: ResearchEvidence.hash(good), evidenceIDs: ["cap-1"], state: .approved, reviewer: "operator"))

        // An unapproved claim: must be excluded, never reported.
        try ledger.propose(.init(id: "hyp-open", content: "Possible IDOR on the invoice endpoint.", meaning: .inference, evidenceIDs: ["cap-1"]))
        return (ledger, hash)
    }

    func testReportContainsOnlyPromotedFindings() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let (ledger, hash) = try populatedLedger(root: root)

        let report = try FindingReport.generate(ledger: ledger, caseID: contract().id, contractHash: hash, program: "HackerOne: acme")
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings.first?.factID, "finding-good")
        XCTAssertEqual(report.findings.first?.receipts.first?.id, "cap-1")
        XCTAssertEqual(report.excluded.count, 1)
        XCTAssertEqual(report.excluded.first?.factID, "hyp-open")
        XCTAssertFalse(report.excluded.first?.blockers.isEmpty ?? true)

        // The markdown reports the finding and its receipt hash, and does not present the excluded claim as a finding.
        XCTAssertTrue(report.markdown.contains("finding-good"))
        XCTAssertTrue(report.markdown.contains(report.findings.first!.receipts.first!.sha256))
        XCTAssertTrue(report.markdown.contains("Program: HackerOne: acme"))
        XCTAssertTrue(report.markdown.contains("Excluded (did not meet the Finding bar)"))
        // Never fabricates severity/impact.
        XCTAssertTrue(report.markdown.contains("_operator to assess_"))
    }

    func testTamperedEvidenceDropsFindingFromReport() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let (ledger, hash) = try populatedLedger(root: root)
        // Tamper the pinned capture after approval — the finding must fall out of the report.
        try Data("DIFFERENT BYTES".utf8).write(to: root.appendingPathComponent("capture.jpg"))

        let report = try FindingReport.generate(ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertTrue(report.findings.isEmpty, "a tampered receipt must demote its claim")
        XCTAssertTrue(report.markdown.contains("No promoted findings"))
        XCTAssertEqual(report.excluded.count, 2)
    }

    func testEmptyLedgerReportsNothing() throws {
        let hash = try contract().digest()
        let ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        let report = try FindingReport.generate(ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.excluded.isEmpty)
        XCTAssertTrue(report.markdown.contains("No promoted findings"))
    }
}
