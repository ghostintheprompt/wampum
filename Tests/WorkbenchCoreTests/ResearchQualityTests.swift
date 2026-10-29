import XCTest
@testable import WorkbenchCore

final class ResearchQualityTests: XCTestCase {
    typealias Q = ResearchQuality
    let body = "# Complete local research\nEvidence is bounded.\n"
    let policy = "Fixture scoring policy"
    let task = "Fixture task"
    let sources = "Fixture sources"
    let trial = #"{"id":"trial-1","caseID":"fixture","condition":"fixture","authorArm":"fixture","state":"completed","configuration":{},"assistance":[]}"#

    func evaluate(_ rubric: Q.Rubric, assessment: Q.Assessment, body: String, policyBody: String? = nil, trialBody: String? = nil) throws -> Q.Report {
        try Q.evaluate(rubric, assessment: assessment, body: body, policy: policyBody ?? policy, task: task, sourceManifest: sources, trialManifest: trialBody ?? trial)
    }

    func fixture() throws -> (Q.Rubric, Q.Assessment) {
        let dimensions = zip(["complete", "security", "code", "evidence", "writing"], [20.0,20,25,20,15]).map { id, weight in
            Q.Dimension(id: id, name: id, weight: weight, criteria: [Q.Criterion(id: id+".a", requirement: "First requirement"), Q.Criterion(id: id+".b", requirement: "Second requirement")])
        }
        let rubric = Q.Rubric(id: "fixture", version: "1", sourceManifestHash: ResearchDocument.digest(sources), policyHash: ResearchDocument.digest(policy), taskHash: ResearchDocument.digest(task), policyFile: "COMMON STANDARD.md", taskFile: "task.json", sourceManifestFile: "sources.json", criticalMinimums: ["code.a":3], passThreshold: 85, dimensionFloor: 75, dimensions: dimensions, gates: [Q.Criterion(id: "truth", requirement: "No fabricated evidence")], requiredUnits: [Q.Criterion(id: "program", requirement: "Complete program")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let witness = directory.appendingPathComponent("review.txt")
        try Data("Fixture host review".utf8).write(to: witness)
        let index = [Q.Evidence(id: "fixture-review", kind: "review", path: witness.path, sha256: ResearchDocument.digest("Fixture host review"), artifactHash: ResearchDocument.digest(body))]
        let assessment = Q.Assessment(rubricID: rubric.id, rubricVersion: rubric.version, rubricHash: try Q.rubricHash(rubric), sourceManifestHash: rubric.sourceManifestHash, artifactHash: ResearchDocument.digest(body), trialManifestHash: ResearchDocument.digest(trial), reviewer: "Host fixture reviewer", evidenceIndex: index, ratings: dimensions.flatMap(\.criteria).map { Q.Rating(criterionID: $0.id, score: 4, evidence: ["fixture-review"]) }, gates: [Q.Check(id: "truth", status: .pass, evidence: ["fixture-review"])], units: [Q.Check(id: "program", status: .pass, evidence: ["fixture-review"])])
        return (rubric, assessment)
    }

    func testCompleteEvidenceLinkedRecordMeetsPolicy() throws {
        let (rubric, assessment) = try fixture()
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.assessedWeight, 100)
        XCTAssertTrue(report.reviewRecordMeetsPolicy)
        XCTAssertTrue(report.limitation.contains("Does not verify evidence truth"))
    }

    func testHighScoreCannotCompensateForFailedGate() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.gates[0].status = .fail
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertEqual(report.score, 100)
        XCTAssertFalse(report.reviewRecordMeetsPolicy)
        XCTAssertEqual(report.failedGates, ["truth"])
    }

    func testMissingChecksAndRatingsRemainUnknown() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.ratings = []; assessment.gates = []; assessment.units = []
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.lowerBound, 0); XCTAssertEqual(report.upperBound, 100)
        XCTAssertEqual(report.assessedWeight, 0)
        XCTAssertEqual(report.unverifiedGates, ["truth"])
        XCTAssertEqual(report.unmetUnits, ["program"])
        XCTAssertFalse(report.reviewRecordMeetsPolicy)
    }

    func testWeightedScoreAndDimensionFloorAreIndependent() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.ratings[0].score = 1; assessment.ratings[1].score = 3
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertEqual(report.score, 90)
        XCTAssertEqual(report.dimensionScores["complete"], 50)
        XCTAssertEqual(report.belowFloor, ["complete"])
        XCTAssertFalse(report.reviewRecordMeetsPolicy)
    }

    func testMissingMandatoryUnitCannotPass() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.units[0].status = .notEvaluated; assessment.units[0].evidence = []
        XCTAssertFalse(try evaluate(rubric, assessment: assessment, body: body).reviewRecordMeetsPolicy)
    }

    func testCurrentDocumentAndRubricBindingsRequired() throws {
        let (rubric, initial) = try fixture()
        XCTAssertThrowsError(try evaluate(rubric, assessment: initial, body: body+"unreviewed"))
        var assessment = initial; assessment.sourceManifestHash = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        var changed = rubric; changed.dimensions[0].criteria[0].requirement = "Different substantive requirement"
        XCTAssertThrowsError(try evaluate(changed, assessment: initial, body: body))
    }

    func testDuplicateAndInventedRatingsRefused() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.ratings.append(initial.ratings[0])
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        assessment = initial; assessment.ratings[0].criterionID = "invented"
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
    }

    func testRatingRangeAndEvidenceAreEnforced() throws {
        let (rubric, initial) = try fixture()
        for value in [-1, 5] {
            var assessment = initial; assessment.ratings[0].score = value
            XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        }
        for value in [0, 4] {
            var assessment = initial; assessment.ratings[0].score = value; assessment.ratings[0].evidence = []
            XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        }
    }

    func testInvalidRubricWeightsAndDuplicateDefinitionsRefused() throws {
        let (initial, assessment) = try fixture()
        for weight in [-1.0, 0, 21, Double.nan, Double.infinity] {
            var rubric = initial; rubric.dimensions[0].weight = weight
            XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        }
        var rubric = initial; rubric.dimensions[1].criteria[0].id = rubric.dimensions[0].criteria[0].id
        var rebound = assessment; rebound.rubricHash = try Q.rubricHash(rubric)
        XCTAssertThrowsError(try evaluate(rubric, assessment: rebound, body: body))
    }

    func testBooleanIsNotAnIntegerRating() throws {
        let (_, assessment) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any])
        var ratings = try XCTUnwrap(object["ratings"] as? [[String: Any]])
        ratings[0]["score"] = true; object["ratings"] = ratings
        XCTAssertThrowsError(try JSONDecoder().decode(Q.Assessment.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testCriticalFailureCannotHideInsidePassingAverage() throws {
        let (initialRubric, initial) = try fixture(); var rubric = initialRubric; var assessment = initial
        for id in ["code.c", "code.d"] {
            rubric.dimensions[2].criteria.append(Q.Criterion(id: id, requirement: "Additional code requirement"))
            assessment.ratings.append(Q.Rating(criterionID: id, score: 4, evidence: ["fixture-review"]))
        }
        assessment.rubricHash = try Q.rubricHash(rubric)
        XCTAssertTrue(try evaluate(rubric, assessment: assessment, body: body).reviewRecordMeetsPolicy)
        if let index = assessment.ratings.firstIndex(where: { $0.criterionID == "code.a" }) { assessment.ratings[index].score = 0 }
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertEqual(report.score, 93.75)
        XCTAssertEqual(report.dimensionScores["code"], 75)
        XCTAssertEqual(report.criticalFailures, ["code.a"])
        XCTAssertFalse(report.reviewRecordMeetsPolicy)
    }

    func testChangedPolicyTrialAndEvidenceCannotReuseReview() throws {
        let (rubric, assessment) = try fixture()
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body, policyBody: policy + "changed anchors"))
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body, trialBody: trial.replacingOccurrences(of: "trial-1", with: "trial-2")))
        try Data("Replaced witness".utf8).write(to: URL(fileURLWithPath: assessment.evidenceIndex[0].path))
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
    }

    func testUnknownEvidenceAndCrossDocumentEvidenceRefused() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.ratings[0].evidence = ["missing-id"]
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        assessment = initial; assessment.evidenceIndex[0].artifactHash = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
    }

    func testFailedUnitsAndUnknownUnitsStayDistinct() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.units[0].status = .fail
        var report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertEqual(report.failedUnits, ["program"]); XCTAssertTrue(report.unverifiedUnits.isEmpty)
        assessment.units = []
        report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertTrue(report.failedUnits.isEmpty); XCTAssertEqual(report.unverifiedUnits, ["program"])
    }

    func testPartialDimensionCanAlreadyBeBelowFloor() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        assessment.ratings[0].score = 0; assessment.ratings[1].score = nil
        let report = try evaluate(rubric, assessment: assessment, body: body)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.dimensionBounds["complete"], [0, 50])
        XCTAssertTrue(report.belowFloor.contains("complete"))
    }

    func testFailedTrialCannotPassQualityRecord() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        let failed = trial.replacingOccurrences(of: "completed", with: "failed")
        assessment.trialManifestHash = ResearchDocument.digest(failed)
        let report = try evaluate(rubric, assessment: assessment, body: body, trialBody: failed)
        XCTAssertEqual(report.score, 100); XCTAssertFalse(report.reviewRecordMeetsPolicy)
        XCTAssertEqual(report.trialState, "failed")
    }

    func testCodeGateRequiresPinnedCodeTestsAndExecution() throws {
        let (initialRubric, initial) = try fixture(); var rubric = initialRubric; var assessment = initial
        rubric.gates.append(Q.Criterion(id: "code", requirement: "Verified mandatory code"))
        assessment.rubricHash = try Q.rubricHash(rubric)
        assessment.gates.append(Q.Check(id: "code", status: .pass, evidence: ["fixture-review"]))
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        for kind in ["code", "test", "execution"] {
            var item = assessment.evidenceIndex[0]; item.id = kind; item.kind = kind
            assessment.evidenceIndex.append(item)
        }
        assessment.gates[1].evidence = ["code", "test", "execution"]
        XCTAssertTrue(try evaluate(rubric, assessment: assessment, body: body).reviewRecordMeetsPolicy)
    }

    func testSaveGateRequiresExactSavedArtifact() throws {
        let (initialRubric, initial) = try fixture(); var rubric = initialRubric; var assessment = initial
        rubric.gates.append(Q.Criterion(id: "save", requirement: "Saved document"))
        assessment.rubricHash = try Q.rubricHash(rubric)
        assessment.gates.append(Q.Check(id: "save", status: .pass, evidence: ["fixture-review"]))
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body))
        let file = URL(fileURLWithPath: assessment.evidenceIndex[0].path).deletingLastPathComponent().appendingPathComponent("document.md")
        try Data(body.utf8).write(to: file)
        assessment.evidenceIndex.append(Q.Evidence(id: "saved", kind: "save", path: file.path, sha256: assessment.artifactHash, artifactHash: assessment.artifactHash))
        assessment.gates[1].evidence = ["saved"]
        XCTAssertTrue(try evaluate(rubric, assessment: assessment, body: body).reviewRecordMeetsPolicy)
    }

    func testCompletedRealComparisonCannotOmitEffectiveConditions() throws {
        let (rubric, initial) = try fixture(); var assessment = initial
        let absent = trial.replacingOccurrences(of: "\"authorArm\":\"fixture\"", with: "\"authorArm\":\"chatgpt\"")
        assessment.trialManifestHash = ResearchDocument.digest(absent)
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body, trialBody: absent))
        let conditions: [String: Any] = ["model": NSNull(), "runtime": NSNull(), "tools": NSNull(), "contextTokens": NSNull(), "outputTokens": NSNull(), "temperature": NSNull(), "thinking": NSNull(), "auditSeed": 0, "auditRule": "Check all claims in fixture", "pairedTrialID": "pair-1", "plannedTrials": 3, "attemptID": "attempt-1", "retryBudget": 0, "assistanceMode": "none declared"]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(absent.utf8)) as? [String: Any])
        object["configuration"] = conditions
        let complete = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        assessment.trialManifestHash = ResearchDocument.digest(complete)
        let report = try evaluate(rubric, assessment: assessment, body: body, trialBody: complete)
        XCTAssertTrue(report.reviewRecordMeetsPolicy)
        XCTAssertEqual(report.authorArm, "chatgpt")
        var invalid = conditions; invalid["plannedTrials"] = true
        object["configuration"] = invalid
        let bad = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        assessment.trialManifestHash = ResearchDocument.digest(bad)
        XCTAssertThrowsError(try evaluate(rubric, assessment: assessment, body: body, trialBody: bad))
    }
}
