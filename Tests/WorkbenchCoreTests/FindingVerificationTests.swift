import XCTest
@testable import WorkbenchCore

final class FindingVerificationTests: XCTestCase {
    private func contract() -> ResearchCaseContract {
        .init(id: "bounty-1", objective: "Demonstrate the access-control claim", roles: ["operator"],
              allowedActions: ["Review captured evidence"], requiredUnits: ["analysis"], rubricSHA256: String(repeating: "a", count: 64))
    }

    /// Builds a ledger with one host-receipt-backed observation fact, optionally approved.
    private func ledger(claim: String, approve: Bool, receiptData: Data = Data("CAPTURED PAGE BYTES".utf8)) throws -> (ResearchEvidence.Ledger, String, URL, String) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = root.appendingPathComponent("capture.jpg")
        try receiptData.write(to: receipt)
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        let evidence = try ResearchEvidence.Evidence.pin(id: "cap-1", caseID: contract().id, contractHash: hash, kind: .hostReceipt, path: receipt.path)
        try ledger.addEvidence(evidence)
        let fact = ResearchEvidence.Fact(id: "claim-1", content: claim, meaning: .observation, evidenceIDs: ["cap-1"])
        try ledger.propose(fact)
        if approve {
            try ledger.recordOperatorReview(.init(factID: "claim-1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["cap-1"], state: .approved, reviewer: "operator"))
        }
        return (ledger, hash, receipt, root.path)
    }

    func testApprovedHostBackedCleanClaimBecomesFinding() throws {
        let claim = "Observed: the export endpoint returned another tenant's records for the attacker session. Captured in the attached receipt."
        let (ledger, hash, _, root) = try ledger(claim: claim, approve: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertTrue(verdict.isFinding, verdict.summary)
        XCTAssertEqual(verdict.backingEvidenceIDs, ["cap-1"])
        XCTAssertTrue(verdict.blockers.isEmpty)
    }

    func testUnapprovedClaimStaysHypothesis() throws {
        let claim = "Observed: cross-tenant read on the export endpoint, shown in the receipt."
        let (ledger, hash, _, root) = try ledger(claim: claim, approve: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding)
        XCTAssertTrue(verdict.blockers.contains { $0.contains("not operator-approved") }, verdict.summary)
    }

    func testFindingGateBlockerKeepsClaimAsHypothesisEvenWhenApproved() throws {
        // Approved and host-backed, but the text carries a severity rating with no demonstrated impact.
        let claim = "CVSS 9.8 critical severity: the endpoint is vulnerable. Captured in the receipt."
        let (ledger, hash, _, root) = try ledger(claim: claim, approve: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding)
        XCTAssertTrue(verdict.blockers.contains { $0.hasPrefix("FindingGate:") }, verdict.summary)
    }

    func testEvidenceChangedOnDiskDemotesToHypothesis() throws {
        let claim = "Observed: the receipt shows the leaked record set for the attacker session."
        let (ledger, hash, receipt, root) = try ledger(claim: claim, approve: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // The pinned capture is tampered with after approval.
        try Data("DIFFERENT BYTES NOW".utf8).write(to: receipt)
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding)
        XCTAssertTrue(verdict.blockers.contains { $0.contains("changed on disk") || $0.contains("missing or unreadable") }, verdict.summary)
        XCTAssertTrue(verdict.backingEvidenceIDs.isEmpty)
    }

    func testScannerLeadSourceReportCannotPromoteToFinding() throws {
        // A Burp-style scanner lead is pinned as sourceReport. Even approved, it cannot
        // become a Finding — promotion requires a captured host receipt, not a tool lead.
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let lead = root.appendingPathComponent("burp-issue.json")
        try Data("{\"name\":\"SQL injection\"}".utf8).write(to: lead)
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        try ledger.addEvidence(try ResearchEvidence.Evidence.pin(id: "burp-0", caseID: contract().id, contractHash: hash, kind: .sourceReport, path: lead.path))
        let claim = "The export endpoint is injectable per the scanner."
        try ledger.propose(.init(id: "claim-1", content: claim, meaning: .reported, evidenceIDs: ["burp-0"]))
        try ledger.recordOperatorReview(.init(factID: "claim-1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["burp-0"], state: .approved, reviewer: "operator"))
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding)
        XCTAssertTrue(verdict.blockers.contains { $0.contains("No host-captured evidence") }, verdict.summary)
    }

    func testModelProposalEvidenceCannotReachApprovedOrPromote() throws {
        // A claim backed only by a model proposal can never be approved by the ledger,
        // so it can never be promoted — model confidence does not become a Finding.
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let note = root.appendingPathComponent("model-note.txt")
        try Data("model says it is probably vulnerable".utf8).write(to: note)
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        try ledger.addEvidence(try ResearchEvidence.Evidence.pin(id: "mp-1", caseID: contract().id, contractHash: hash, kind: .modelProposal, path: note.path))
        try ledger.propose(.init(id: "claim-1", content: "The endpoint is vulnerable.", meaning: .inference, evidenceIDs: ["mp-1"]))
        // The ledger refuses to approve a model-proposal-backed fact.
        XCTAssertThrowsError(try ledger.recordOperatorReview(.init(factID: "claim-1", contentHash: ResearchEvidence.hash("The endpoint is vulnerable."), evidenceIDs: ["mp-1"], state: .approved, reviewer: "operator")))
        let verdict = try FindingVerification.verify(factID: "claim-1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding)
        XCTAssertTrue(verdict.blockers.contains { $0.contains("not operator-approved") })
        XCTAssertTrue(verdict.blockers.contains { $0.contains("No host-captured evidence") })
    }
}
