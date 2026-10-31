import XCTest
@testable import WorkbenchCore

/// Client-grade hardening: untrusted-input parsing (XXE / entity expansion) and adversarial
/// attempts to promote a fake finding. Each asserts the secure behavior.
final class HardeningTests: XCTestCase {
    // MARK: - XML parser must not resolve external entities (XXE) or expand entity bombs

    func testNmapXXEDoesNotLeakLocalFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretFile = root.appendingPathComponent("xxe-secret.txt")
        try Data("XXE_LEAK_MARKER_9f3a".utf8).write(to: secretFile)
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE nmaprun [ <!ENTITY xxe SYSTEM "file://\(secretFile.path)"> ]>
        <nmaprun scanner="nmap"><host><address addr="10.0.0.5" addrtype="ipv4"/>
        <ports><port protocol="tcp" portid="22"><state state="open"/><service name="&xxe;"/></port></ports></host></nmaprun>
        """
        let results = (try? NmapImport.results(from: Data(xml.utf8))) ?? []
        for r in results {
            XCTAssertFalse(r.service.contains("XXE_LEAK_MARKER"), "XXE: external entity resolved and leaked a local file into service name")
            XCTAssertFalse(r.product.contains("XXE_LEAK_MARKER"), "XXE: leaked into product")
            XCTAssertFalse(r.scriptOutput.contains("XXE_LEAK_MARKER"), "XXE: leaked into script output")
        }
    }

    func testNmapEntityBombDoesNotExplode() {
        // Billion-laughs style nested entities must not hang or blow memory.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
          <!ENTITY a "aaaaaaaaaa">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
        ]>
        <nmaprun><host><address addr="1.1.1.1" addrtype="ipv4"/>
        <ports><port protocol="tcp" portid="1"><state state="open"/><service name="&d;"/></port></ports></host></nmaprun>
        """
        // Just needs to return (throw or bounded result) without exploding the expanded string.
        let results = (try? NmapImport.results(from: Data(xml.utf8))) ?? []
        for r in results { XCTAssertLessThan(r.service.count, 100_000, "entity bomb expanded into service name") }
    }

    // MARK: - FindingVerification: a tampered or mismatched claim must not promote

    private func contract() -> ResearchCaseContract {
        .init(id: "harden", objective: "x", roles: ["op"], allowedActions: ["a"], requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64))
    }

    func testClaimTamperedAfterApprovalCannotPromote() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        let cap = root.appendingPathComponent("c.bin"); try Data("CAP".utf8).write(to: cap)
        try ledger.addEvidence(try .pin(id: "e1", caseID: contract().id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        let realClaim = "Observed: benign note about the response, captured."
        try ledger.propose(.init(id: "f1", content: realClaim, meaning: .observation, evidenceIDs: ["e1"]))
        // Operator approves a DIFFERENT contentHash than the proposed claim (tamper/mismatch).
        XCTAssertThrowsError(try ledger.recordOperatorReview(.init(factID: "f1", contentHash: ResearchEvidence.hash("a totally different claim"), evidenceIDs: ["e1"], state: .approved, reviewer: "op")),
                             "ledger accepted an approval whose contentHash did not match the claim")
    }

    func testApprovalBoundToStaleEvidenceSetDoesNotSilentlyPromote() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = try contract().digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract().id, contractHash: hash)
        let cap = root.appendingPathComponent("c.bin"); try Data("CAP".utf8).write(to: cap)
        try ledger.addEvidence(try .pin(id: "e1", caseID: contract().id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        let claim = "Observed: real cross-tenant read, captured in the receipt."
        try ledger.propose(.init(id: "f1", content: claim, meaning: .observation, evidenceIDs: ["e1"]))
        try ledger.recordOperatorReview(.init(factID: "f1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["e1"], state: .approved, reviewer: "op"))
        // Now the capture is swapped on disk after approval — must demote.
        try Data("SWAPPED".utf8).write(to: cap)
        let verdict = try FindingVerification.verify(factID: "f1", ledger: ledger, caseID: contract().id, contractHash: hash)
        XCTAssertFalse(verdict.isFinding, "a receipt swapped after approval still promoted")
    }

    // MARK: - Scope: more exotic hosts

    func testScopeTrailingDotAndExotic() {
        let scope = AuthorizedScope(["example.com", "*.api.example.com"])
        // Trailing-dot FQDN of an out-of-scope host must not match.
        XCTAssertFalse(scope.matches(host: "evil.com."))
        // Punycode/IDN lookalike of example.com must not match the ASCII entry.
        XCTAssertFalse(scope.matches(host: "xn--exmple-cua.com"))
        // Embedded whitespace / newline injection in a host must not match.
        XCTAssertFalse(scope.matches(host: "example.com\nevil.com"))
        XCTAssertFalse(scope.matches(host: "api.example.com evil.com"))
    }
}
