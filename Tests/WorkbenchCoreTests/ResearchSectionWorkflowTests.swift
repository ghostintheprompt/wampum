import XCTest
@testable import WorkbenchCore

final class ResearchSectionWorkflowTests: XCTestCase {
    private let contract = ResearchSectionWorkflow.hash(Data("contract".utf8))
    private let body = "## Analysis\nA substantive fixture explanation with explicit limits and evidence.\n"
    private var sources: [SectionSource] { [SectionSource(id: "source", contentHash: ResearchSectionWorkflow.hash(Data("source bytes".utf8)))] }
    private var evidence: [SectionReviewEvidence] { [SectionReviewEvidence(reference: "review/file#L12", contentHash: contract, explanation: "Reviewed completeness against the frozen section requirements.")] }
    private func workflow(_ ids: [String] = ["one"]) throws -> ResearchSectionWorkflow {
        try ResearchSectionWorkflow(caseID: "case", contractHash: contract, requiredSectionIDs: ids, sources: sources)
    }
    private func attempt(_ id: String = "one", body: String? = nil, stop: String? = "stop", sources: [SectionSource]? = nil) -> SectionGenerationAttempt {
        SectionGenerationAttempt(sectionID: id, caseID: "case", contractHash: contract, body: body ?? self.body,
                                 stopReason: stop, outputTokens: 42, inputTokens: 120, sources: sources ?? self.sources,
                                 provenance: SectionModelProvenance(model: "fixture-only", modelDigest: "observed-digest", requestID: "fixture-request"))
    }
    private func review(_ attempt: SectionGenerationAttempt, _ decision: SectionReviewDecision = .approve) throws -> SectionHumanReview {
        SectionHumanReview(attemptID: attempt.id, bindingHash: try attempt.bindingHash, reviewer: "human", decision: decision, evidence: evidence)
    }
    private func accepted() throws -> ResearchSectionWorkflow {
        var w = try workflow(); let a = attempt(); try w.record(a); try w.review(review(a)); return w
    }
    func testMissingChaptersAndDroppedRequirements() throws {
        var w = try workflow(["one", "two"]); let a = attempt(); try w.record(a); try w.review(review(a))
        XCTAssertEqual(try w.state(for: "two"), .missing)
        XCTAssertThrowsError(try w.assemble(expectedRequiredSectionIDs: ["one", "two"]))
        XCTAssertThrowsError(try w.assemble(expectedRequiredSectionIDs: ["one"]))
        XCTAssertThrowsError(try workflow(["one", "one"]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any])
        object["requiredSectionIDs"] = ["one"]
        let shortened = try JSONDecoder().decode(ResearchSectionWorkflow.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try shortened.assemble(expectedRequiredSectionIDs: ["one", "two"]))
    }
    func testPartialRejectedAndRetryHistorySurvivesRoundTrip() throws {
        var w = try workflow(); let partial = attempt(stop: "length")
        try w.record(partial); XCTAssertThrowsError(try w.review(review(partial)))
        try w.review(review(partial, .reject))
        let rejected = attempt(); try w.record(rejected); try w.review(review(rejected, .reject))
        XCTAssertEqual(try w.state(for: "one"), .rejected)
        let good = attempt(); try w.record(good); try w.review(review(good))
        let restored = try JSONDecoder().decode(ResearchSectionWorkflow.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(restored.attempts, [partial, rejected, good]); XCTAssertEqual(restored.reviews.count, 3)
        XCTAssertEqual(restored.attempts[0].outputTokens, 42); XCTAssertEqual(restored.attempts[0].stopReason, "length")
        XCTAssertEqual(try restored.state(for: "one"), .accepted)
        XCTAssertThrowsError(try w.record(good))
        let retry = attempt(stop: nil); try w.record(retry)
        XCTAssertEqual(try w.state(for: "one"), .incomplete)
        XCTAssertThrowsError(try w.assemble(expectedRequiredSectionIDs: ["one"]))
    }
    func testSourcesContractAndContentStaleApproval() throws {
        var w = try accepted()
        let changed = [SectionSource(id: "source", contentHash: contract)]
        try w.revise(contractHash: contract, sources: changed)
        XCTAssertEqual(try w.state(for: "one"), .stale)
        XCTAssertThrowsError(try w.review(review(w.attempts[0])))
        try w.revise(contractHash: ResearchSectionWorkflow.hash(Data("new contract".utf8)), sources: sources)
        XCTAssertEqual(try w.state(for: "one"), .stale)
        var fresh = try accepted(); let changedBody = attempt(body: body + "Changed bytes.")
        try fresh.record(changedBody); XCTAssertEqual(try fresh.state(for: "one"), .awaitingReview)
        XCTAssertThrowsError(try fresh.review(review(fresh.attempts[0])))
        var omitted = try workflow(); try omitted.record(attempt(sources: []))
        XCTAssertEqual(try omitted.state(for: "one"), .stale)
    }
    func testUnknownStopsMalformedAndHeaderOnlyCannotBeApproved() throws {
        for candidate in [attempt(stop: "unknown"), attempt(stop: nil), attempt(stop: "length"),
                          attempt(body: "# Title\n## Section\n"), attempt(body: "# Title\nTODO"), attempt(body: "# Title\nTODO: Write the missing substantive analysis here."),
                          attempt(body: body + "```swift\nlet x = 1\n")] {
            var w = try workflow(); try w.record(candidate)
            XCTAssertEqual(try w.state(for: "one"), .incomplete)
            XCTAssertThrowsError(try w.review(review(candidate)))
        }
        var w = try workflow(); let a = attempt(); try w.record(a)
        XCTAssertEqual(try w.state(for: "one"), .awaitingReview)
        XCTAssertThrowsError(try w.assemble(expectedRequiredSectionIDs: ["one"]))
        let noEvidence = SectionHumanReview(attemptID: a.id, bindingHash: try a.bindingHash, reviewer: "human", decision: .approve, evidence: [])
        XCTAssertThrowsError(try w.review(noEvidence))
    }
    func testUnicodeAndNestedFencesKeepExactBytes() throws {
        let text = "## Résumé 東京\nThis fixture retains Unicode and a longer enclosing fence exactly.\n````markdown\n```swift\nlet x = 1\n```\n````\n"
        var w = try workflow(); let a = attempt(body: text); try w.record(a); try w.review(review(a))
        let result = try w.assemble(expectedRequiredSectionIDs: ["one"])
        XCTAssertEqual(result.bytes, Data(text.utf8)); XCTAssertEqual(result.documentHash, ResearchSectionWorkflow.hash(Data(text.utf8)))
        XCTAssertEqual(result.status, .draft)
    }
    func testGateRequiresHostValidationAndExactResultBytes() throws {
        let w = try accepted(); let draft = try w.assemble(expectedRequiredSectionIDs: ["one"])
        let gate = SectionHostQualityGate(caseID: "case", contractHash: contract, documentHash: draft.documentHash, reviewer: "host reviewer", evidence: evidence)
        XCTAssertEqual(try w.assemble(expectedRequiredSectionIDs: ["one"], qualityGate: gate).status, .draft)
        XCTAssertEqual(try w.assemble(expectedRequiredSectionIDs: ["one"], qualityGate: gate, validateHostGate: { _, _ in false }).status, .draft)
        let reviewed = try w.assemble(expectedRequiredSectionIDs: ["one"], qualityGate: gate, validateHostGate: { _, bytes in bytes == draft.bytes })
        XCTAssertEqual(reviewed.status, .hostReviewed)
        let wrong = SectionHostQualityGate(caseID: "case", contractHash: contract, documentHash: ResearchSectionWorkflow.hash(draft.bytes + Data([10])), reviewer: "host", evidence: evidence)
        XCTAssertEqual(try w.assemble(expectedRequiredSectionIDs: ["one"], qualityGate: wrong, validateHostGate: { _, _ in XCTFail("Wrong bytes must not reach host approval"); return true }).status, .draft)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(reviewed), as: UTF8.self).contains("verified"))
    }
    func testTamperedDecodedBodyAndBindingsAreRejected() throws {
        let w = try accepted()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any])
        var attempts = try XCTUnwrap(object["attempts"] as? [[String: Any]])
        attempts[0]["body"] = body + "Changed"; object["attempts"] = attempts
        XCTAssertThrowsError(try JSONDecoder().decode(ResearchSectionWorkflow.self, from: JSONSerialization.data(withJSONObject: object)))
        attempts[0]["bodyHash"] = ResearchSectionWorkflow.hash(Data((body + "Changed").utf8)); object["attempts"] = attempts
        XCTAssertThrowsError(try JSONDecoder().decode(ResearchSectionWorkflow.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
