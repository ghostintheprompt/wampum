import XCTest
@testable import WorkbenchCore

final class TestVariationTests: XCTestCase {
    func testReactionClassification() {
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 200, markers: []), .allowed)
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 403, markers: []), .blocked)
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 429, markers: []), .rateLimited)
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 401, markers: []), .authRequired)
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 503, markers: []), .serverError)
        // A 200 that serves a captcha is a challenge, not an allow — markers override status.
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 200, markers: ["captcha"]), .challenged)
        XCTAssertEqual(TestVariationAnalysis.reaction(status: 200, markers: ["waf-block"]), .blocked)
    }

    func testNoDifferentialWhenAllReactSame() throws {
        let base = VariationObservation(label: "baseline", status: 200, bodySHA256: "a", bodyBytes: 10)
        let v1 = VariationObservation(label: "ua-rotated", status: 200, bodySHA256: "b", bodyBytes: 11)
        let v2 = VariationObservation(label: "spaced", status: 200, bodySHA256: "c", bodyBytes: 12)
        let signal = try TestVariationAnalysis.evaluate(baseline: base, variations: [v1, v2])
        XCTAssertFalse(signal.detectionObserved)
        XCTAssertTrue(signal.differingVariations.isEmpty)
        XCTAssertEqual(signal.baselineReaction, .allowed)
    }

    func testDetectionDifferentialIsALead() throws {
        // Baseline allowed; one variation blocked, one rate-limited → the defense distinguishes them.
        let base = VariationObservation(label: "baseline", status: 200, bodySHA256: "a", bodyBytes: 10)
        let blocked = VariationObservation(label: "payload-A", status: 403, bodySHA256: "b", bodyBytes: 5)
        let limited = VariationObservation(label: "burst", status: 429, bodySHA256: "c", bodyBytes: 5)
        let signal = try TestVariationAnalysis.evaluate(baseline: base, variations: [blocked, limited])
        XCTAssertTrue(signal.detectionObserved)
        XCTAssertEqual(Set(signal.differingVariations), ["payload-A", "burst"])
        XCTAssertEqual(signal.reactions["payload-A"], "blocked")
        XCTAssertEqual(signal.reactions["burst"], "rateLimited")
        // Framed as a lead to verify + capture, never as a finding.
        XCTAssertTrue(signal.detail.contains("LEAD"))
        XCTAssertTrue(signal.detail.lowercased().contains("verify"))
    }

    func testDuplicateLabelsRejected() {
        let base = VariationObservation(label: "baseline", status: 200, bodySHA256: "a", bodyBytes: 1)
        let dup = VariationObservation(label: "baseline", status: 403, bodySHA256: "b", bodyBytes: 1)
        XCTAssertThrowsError(try TestVariationAnalysis.evaluate(baseline: base, variations: [dup]))
    }

    func testVariationPreservesExactInputs() throws {
        // The variation records exactly what it changes — not a hidden transform.
        let v = RequestVariation(label: "ua-rotated", headerOverrides: ["User-Agent": "test-bot/1.0"], delayMs: 250, note: "rotate UA + 250ms spacing")
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(RequestVariation.self, from: data)
        XCTAssertEqual(back, v)
        XCTAssertEqual(back.headerOverrides["User-Agent"], "test-bot/1.0")
        XCTAssertEqual(back.delayMs, 250)
    }
}
