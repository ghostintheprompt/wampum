import XCTest
@testable import WorkbenchCore

/// Deep fuzzing of the untrusted-input parsers and stress on the evidence ledger.
/// Every parser must THROW or return gracefully on garbage — never crash, hang, or force-unwrap.
final class FuzzTests: XCTestCase {
    // Adversarial byte payloads thrown at every JSON parser.
    private var jsonGarbage: [Data] {
        var out: [Data] = [
            Data(),                                             // empty
            Data("{".utf8),                                     // truncated
            Data("[]".utf8),                                    // array, not object
            Data("null".utf8),
            Data("\"a string\"".utf8),
            Data("42".utf8),
            Data("{\"\u{0}\":\"\u{0}\"}".utf8),                 // null bytes in keys/values
            Data(([UInt8](repeating: 0xFF, count: 256))),       // invalid UTF-8
            Data("{\"results\":\"not-an-array\"}".utf8),        // wrong type where array expected
            Data("{\"results\":[1,2,3]}".utf8),                 // array of non-objects
            Data("{\"paths\":42,\"openapi\":\"3.0.0\"}".utf8),  // wrong-typed paths
            Data("{\"openapi\":[],\"paths\":{}}".utf8),
        ]
        // Deeply nested JSON (parser-depth bomb) — must not crash.
        out.append(Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8))
        // Big but under caps: many empty objects.
        out.append(Data(("{\"results\":[" + Array(repeating: "{}", count: 20_000).joined(separator: ",") + "]}").utf8))
        return out
    }

    func testJSONParsersNeverCrashOnGarbage() {
        for g in jsonGarbage {
            // Each call must either throw or return a value; the test passing = no crash/hang.
            _ = try? OpenAPIImport.operations(from: g)
            _ = try? SemgrepImport.findings(from: g)
            _ = try? FfufImport.results(from: g)
            _ = try? NmapImport.results(from: g)
        }
        XCTAssertTrue(true, "all parsers survived the garbage battery")
    }

    func testNmapXMLGarbageNeverCrashes() {
        let xmls = [
            Data("<".utf8),
            Data("<nmaprun>".utf8),                                           // unterminated
            Data("<nmaprun><host><ports><port portid=\"x\"/></ports></host></nmaprun>".utf8), // non-numeric port
            Data(("<nmaprun>" + String(repeating: "<host></host>", count: 50_000) + "</nmaprun>").utf8),
            Data("<nmaprun>\u{0}\u{1}\u{2}</nmaprun>".utf8),                  // control chars
        ]
        for x in xmls { _ = try? NmapImport.results(from: x) }
        // Greppable garbage
        _ = try? NmapImport.results(from: Data("Host: \t\t\t\nPorts:::::\n".utf8))
        XCTAssertTrue(true, "nmap XML/greppable parser survived garbage")
    }

    func testReconPlanHandlesHostileTargets() {
        let scope = AuthorizedScope(["example.com"])
        let exe = URL(fileURLWithPath: "/bin/echo")
        for t in ["", " ", "\n", "https://", "http://@", " h t t p", "example.com\u{0}", "example.com/../../etc"] {
            XCTAssertNoThrow({ _ = try? ReconControl.plan(tool: .nmap, executable: exe, target: t, extraArgs: [], scope: scope) }(),
                             "ReconControl.plan crashed on target '\(t)'")
        }
    }

    func testAIProbesHandleEmptyAndHugeInput() {
        let huge = String(repeating: "A", count: 2_000_000)
        _ = PromptInjectionProbe.evaluate(response: "", secretMarker: "X")
        _ = PromptInjectionProbe.evaluate(response: huge, secretMarker: "X")
        _ = PromptInjectionProbe.evaluate(response: huge, secretMarker: "")   // empty marker
        _ = GuardrailRobustnessProbe.mutations(of: "")
        _ = GuardrailRobustnessProbe.evaluate(baselineResponse: "", mutationResponses: [])
        _ = MultimodalInjectionProbe.evaluate(imageTextLayer: huge, vlmResponse: huge, secretMarker: "X")
        XCTAssertTrue(true, "AI probes survived empty/huge input")
    }

    // MARK: - Ledger stress: adversarial mutation sequences stay consistent, never crash

    func testLedgerAdversarialSequences() throws {
        let contract = ResearchCaseContract(id: "fuzz", objective: "x", roles: ["op"], allowedActions: ["a"], requiredUnits: ["r"], rubricSHA256: String(repeating: "a", count: 64))
        let hash = try contract.digest()
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cap = root.appendingPathComponent("c.bin"); try Data("CAP".utf8).write(to: cap)
        var ledger = ResearchEvidence.Ledger(caseID: contract.id, contractHash: hash)
        try ledger.addEvidence(try .pin(id: "e1", caseID: contract.id, contractHash: hash, kind: .hostReceipt, path: cap.path))

        // Approve a fact that was never proposed -> must fail, not corrupt state.
        XCTAssertThrowsError(try ledger.recordOperatorReview(.init(factID: "ghost", contentHash: "x", evidenceIDs: ["e1"], state: .approved, reviewer: "op")))
        // Propose referencing missing evidence -> must fail.
        XCTAssertThrowsError(try ledger.propose(.init(id: "bad", content: "c", meaning: .observation, evidenceIDs: ["nope"])))
        // Duplicate evidence id -> must fail.
        XCTAssertThrowsError(try ledger.addEvidence(try .pin(id: "e1", caseID: contract.id, contractHash: hash, kind: .hostReceipt, path: cap.path)))

        // A valid propose+approve still works after all the rejected attempts (state intact).
        let claim = "Observed: real thing, captured."
        try ledger.propose(.init(id: "f1", content: claim, meaning: .observation, evidenceIDs: ["e1"]))
        try ledger.recordOperatorReview(.init(factID: "f1", contentHash: ResearchEvidence.hash(claim), evidenceIDs: ["e1"], state: .approved, reviewer: "op"))
        XCTAssertEqual(try ledger.state(of: "f1"), .approved)
        // The ledger refuses an evidence-free claim (good: no unfounded findings).
        XCTAssertThrowsError(try ledger.propose(.init(id: "evfree", content: "no evidence", meaning: .reported, evidenceIDs: [])))
        // Many rapid, evidence-backed proposals don't corrupt or crash.
        for i in 0..<300 { try ledger.propose(.init(id: "p\(i)", content: "c\(i)", meaning: .reported, evidenceIDs: ["e1"])) }
        XCTAssertEqual(try ledger.state(of: "f1"), .approved)
    }
}
