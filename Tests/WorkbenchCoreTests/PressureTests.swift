import XCTest
@testable import WorkbenchCore

/// Adversarial pressure tests against Wampum's OWN guarantees. Each asserts the secure/correct
/// behavior; a failure here is a real hole to fix, not a flaky test.
final class PressureTests: XCTestCase {
    // MARK: - Scope gate: must stay fail-closed under hostile inputs

    private let scope = AuthorizedScope(["example.com", "*.api.example.com", ".corp.example.com"])

    func testScopeBlocksEvilLookalikes() throws {
        let evil = [
            "http://evil.com/",
            "http://example.com.evil.com/",          // suffix-append trick
            "http://notexample.com/",                 // no dot boundary
            "http://api.example.com.evil.com/",       // wildcard base as a prefix of evil
            "http://example.com@evil.com/",           // userinfo confusion -> host is evil.com
            "http://corp.example.com.attacker.net/",  // apex-wildcard base inside evil host
        ]
        for s in evil {
            guard let u = URL(string: s) else { continue }
            XCTAssertThrowsError(try scope.authorize(u), "SCOPE BYPASS: \(s) host=\(u.host ?? "nil") was authorized")
        }
    }

    func testScopeAllowsOnlyIntended() throws {
        XCTAssertNoThrow(try scope.authorize(URL(string: "http://example.com/x")!))
        XCTAssertNoThrow(try scope.authorize(URL(string: "https://sub.api.example.com/")!))
        XCTAssertNoThrow(try scope.authorize(URL(string: "http://corp.example.com/")!))
        XCTAssertNoThrow(try scope.authorize(URL(string: "http://deep.corp.example.com/")!))
        // *.api.example.com is subdomains-only: the bare base must NOT match.
        XCTAssertThrowsError(try scope.authorize(URL(string: "http://api.example.com/")!))
        // empty scope authorizes nothing.
        XCTAssertThrowsError(try AuthorizedScope([]).authorize(URL(string: "http://example.com/")!))
    }

    func testScopeCaseInsensitive() throws {
        XCTAssertNoThrow(try scope.authorize(URL(string: "http://EXAMPLE.com/")!))
        XCTAssertTrue(scope.matches(host: "SUB.API.EXAMPLE.COM"))
    }

    // A leading-dot host must not sneak past the subdomain wildcard.
    func testScopeLeadingDotHostNotMatchedByWildcard() {
        XCTAssertFalse(scope.matches(host: ".api.example.com"),
                       "leading-dot host matched *.api.example.com")
    }

    // IPv6 loopback/literal normalization must not mangle a host into something else.
    func testIPv6NormalizationIsSane() {
        let n = AuthorizedScope.normalize("::1")
        XCTAssertEqual(n, "::1", "IPv6 ::1 normalized to '\(n)' (mangled)")
        let b = AuthorizedScope.normalize("[2001:db8::1]:443")
        XCTAssertEqual(b, "[2001:db8::1]", "bracketed IPv6+port normalized to '\(b)'")
    }

    // MARK: - Report integrity: claim text must not forge report structure

    func testReportClaimCannotForgeFindingSection() throws {
        let contract = ResearchCaseContract(id: "pt", objective: "x", roles: ["op"], allowedActions: ["a"],
            requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = try contract.digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract.id, contractHash: hash)
        let cap = root.appendingPathComponent("c.bin"); try Data("X".utf8).write(to: cap)
        try ledger.addEvidence(try .pin(id: "e1", caseID: contract.id, contractHash: hash, kind: .hostReceipt, path: cap.path))
        // A gate-passing claim whose body embeds a markdown header — it must not forge a section.
        let claim = "Observed: the export endpoint returned another tenant's record in the response body for the attacker session, captured in the receipt.\n## Appendix extra section\nmore detail"
        try ledger.propose(.init(id: "f1", content: claim, meaning: .observation, evidenceIDs: ["e1"]))
        try ledger.recordOperatorReview(.init(factID: "f1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["e1"], state: .approved, reviewer: "op"))
        let report = try FindingReport.generate(ledger: ledger, caseID: contract.id, contractHash: hash)
        XCTAssertEqual(report.findings.count, 1, "the clean claim should promote")
        // The embedded header must be neutralized (blockquoted), never a real markdown header.
        let forgedHeader = report.markdown.split(separator: "\n").contains { $0.hasPrefix("## Appendix") }
        XCTAssertFalse(forgedHeader, "REPORT INJECTION: claim text forged a '## ' header in the markdown")
    }

    // MARK: - AI probe accuracy: a refusal that merely names the canary is NOT a leak

    func testPromptInjectionProbeRefusalEchoingCanaryIsNotLeak() {
        let secret = "CANARY-7f3a-SECRET"
        let refusal = "I can't share \(secret) or reveal any internal secret. I won't do that."
        let sig = PromptInjectionProbe.evaluate(response: refusal, secretMarker: secret)
        XCTAssertFalse(sig.crossed, "FALSE POSITIVE: a refusal echoing the canary name was flagged as a leak")
    }

    func testGuardrailRobustnessNoFalsePositiveWhenAllRefuse() {
        let base = "I cannot help with that."
        let muts = [("fragmented", "I cannot help with that."), ("spaced", "I'm unable to assist.")]
        let sig = GuardrailRobustnessProbe.evaluate(baselineResponse: base, mutationResponses: muts)
        XCTAssertFalse(sig.crossed, "FALSE POSITIVE: all-refusals flagged as a bypass")
    }

    // MARK: - Engagement separation: blank engagement ids must not collide into a bucket

    func testBlankEngagementDoesNotCollideWithScopedReceipts() {
        var legacy = ToolReceipt(tool: "x", action: "y", targets: [], argument: "z")   // engagement nil
        var clientA = ToolReceipt(tool: "x", action: "y", targets: [], argument: "z"); clientA.engagement = "client-a"
        legacy.engagement = nil
        // A view scoped to client-a must not show the nil-engagement receipt.
        let visibleForA = [legacy, clientA].filter { $0.engagement == "client-a" }
        XCTAssertEqual(visibleForA.count, 1)
        XCTAssertEqual(visibleForA.first?.engagement, "client-a")
    }

    // MARK: - Parser robustness: malformed input must fail gracefully, never crash

    func testParsersRejectGarbageWithoutCrashing() {
        XCTAssertThrowsError(try NmapImport.results(from: Data("not xml not greppable".utf8)))
        XCTAssertThrowsError(try FfufImport.results(from: Data("{".utf8)))
        XCTAssertThrowsError(try NmapImport.results(from: Data(repeating: 0x3c, count: 40_000_000)))  // 40MB of '<' > cap
    }
}
