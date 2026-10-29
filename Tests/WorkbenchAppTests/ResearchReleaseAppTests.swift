import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ResearchReleaseAppTests: XCTestCase {
    typealias Q = ResearchQuality
    struct Fixture {
        let root: URL
        let model: WorkbenchModel
        let paths: ResearchRelease.Paths
        var assessment: Q.Assessment
        let rubric: Q.Rubric
        let source: ResearchSourceCapture
    }
    func write<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url)
    }
    @MainActor func fixture(root provided: URL? = nil, gap: Bool = false) throws -> Fixture {
        let root = provided ?? URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw WorkbenchError.invalid("Fixture output already exists.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if provided == nil { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        let sourceFile = root.appendingPathComponent("source.txt")
        let sourceData = Data(("Host-authored synthetic source. " + String(repeating: "s", count: 2200)).utf8)
        try sourceData.write(to: sourceFile)
        var capture = try ResearchSourceIngestor.capture(reviewed: ResearchSourceIngestor.review(url: sourceFile))
        if gap {
            capture = .init(original: capture.original, format: .utf8Text, extractedText: capture.extractedText,
                extractedTextSHA256: capture.extractedTextSHA256, warnings: ["Synthetic extraction-uncertainty fixture"], pages: [], fullDocumentTextCoverage: false)
        }
        let policy = "Host fixture policy. These supplied scores and receipts are synthetic, not a model or empirical execution outcome."
        let task = "Review two complete fixture sections and preserve all source allocations."
        try Data(policy.utf8).write(to: root.appendingPathComponent("policy.txt"))
        try Data(task.utf8).write(to: root.appendingPathComponent("task.txt"))
        let snapshot = try JSONSerialization.data(withJSONObject: ["task_sha256": ResearchDocument.digest(task), "sources": [["path": sourceFile.path, "bytes": sourceData.count, "sha256": capture.original.sha256]]], options: [.sortedKeys])
        try snapshot.write(to: root.appendingPathComponent("sources.json"))
        let units = ["analysis", "verification"]
        let rubric = Q.Rubric(id: "release-fixture", version: "1", sourceManifestHash: ResearchSectionWorkflow.hash(snapshot), policyHash: ResearchDocument.digest(policy), taskHash: ResearchDocument.digest(task), policyFile: "policy.txt", taskFile: "task.txt", sourceManifestFile: "sources.json", criticalMinimums: ["quality": 3], passThreshold: 85, dimensionFloor: 75,
            dimensions: [.init(id: "fixture", name: "Synthetic quality", weight: 100, criteria: [.init(id: "quality", requirement: "Review the complete fixture artifact")])],
            gates: [.init(id: "code", requirement: "Indexed code/test/isolated receipt consistency"), .init(id: "save", requirement: "Exact draft bytes"), .init(id: "sources", requirement: "Original source review")],
            requiredUnits: units.map { .init(id: $0, requirement: "Complete fixture section " + $0) })
        let contract = ResearchCaseContract(id: rubric.id, objective: "Exercise native release controls with explicitly labeled host fixtures", roles: ["fixture operator"], allowedActions: ["read local fixture files"], requiredUnits: units, rubricSHA256: try Q.rubricHash(rubric))
        var state = try ResearchCaseState(contract: contract, sources: [capture])
        state.sourcePlan = try ResearchSourcePlan(contract: contract)
        let windows = try capture.windows(maxUTF8Bytes: 2048)
        for window in windows { state.sourcePlan?.setSelected(true, unitID: window.index == 0 ? units[0] : units[1], capture: capture, window: window) }
        state.activeSourceUnit = units[0]; state.sectionInstructions = [units[0]: "Analyze the complete synthetic source and indexed code.", units[1]: "Explain actual fixture limitations and review evidence."]
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state")); model.session.project = root.path; model.session.researchCase = state
        let code = "def echo(value):\n    return value\n"
        let oracle = "import unittest\nclass EchoTests(unittest.TestCase):\n    def test_text(self): self.assertEqual(echo('x'), 'x')\n    def test_empty(self): self.assertEqual(echo(''), '')\n    def test_number(self): self.assertEqual(echo(7), 7)\n"
        let review = root.appendingPathComponent("review.txt")
        try Data("Host-authored review record for a synthetic test, not a real model or execution result.".utf8).write(to: review)
        for unit in units {
            model.session.researchCase?.activeSourceUnit = unit
            let selected = try XCTUnwrap(model.session.researchCase)
            let binding = try ResearchSectionRequest(state: selected, additionalSources: [model.sectionContextBinding()])
            let body = unit == units[0] ? "# Analysis\nHost-authored synthetic analysis with explicitly bounded evidence.\n```python\n" + code + "```\n" : "# Verification\nThese scores and execution records are host-authored fixtures. No Qwen generation or empirical code execution is established by this artifact."
            try model.recordResearchSection(binding, body: body, stopReason: "stop", outputTokens: 40, inputTokens: 100, model: "host-fixture-no-model", requestID: "fixture-no-model-journal")
            let attempt = try XCTUnwrap(model.session.researchCase?.sectionWorkflow?.attempts.last)
            try model.reviewResearchSection(attemptID: attempt.id, expectedBinding: attempt.bindingHash, reviewer: "Fixture reviewer", explanation: "Inspected the synthetic content and explicitly documented its fixture-only limitations.", evidenceURL: review, decision: .approve)
        }
        let draft = try model.researchSectionsDraft()
        try draft.bytes.write(to: root.appendingPathComponent("draft.md"))
        try Data(code.utf8).write(to: root.appendingPathComponent("code.py")); try Data(oracle.utf8).write(to: root.appendingPathComponent("oracle.py"))
        let run: [String: Any] = ["fixture": true, "oracleIsolation": "sandbox-exec-worker", "independentOracle": true, "passed": true, "tests": 3, "failures": 0, "errors": 0, "skipped": 0, "calls": 3, "subjectSHA256": ResearchDocument.digest(code), "oracleSHA256": ResearchDocument.digest(oracle)]
        try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys]).write(to: root.appendingPathComponent("execution.json"))
        let trial = Q.Trial(id: "fixture-trial", caseID: rubric.id, condition: "Synthetic native-gate fixture, no model result", authorArm: "fixture", state: "completed", configuration: [:], assistance: ["All artifact content, ratings and receipts authored by the host test"])
        let paths = ResearchRelease.Paths(rubric: root.appendingPathComponent("rubric.json").path, assessment: root.appendingPathComponent("assessment.json").path, trial: root.appendingPathComponent("trial.json").path)
        try write(rubric, URL(fileURLWithPath: paths.rubric)); try write(trial, URL(fileURLWithPath: paths.trial))
        let evidence = try [("code", "code.py"), ("test", "oracle.py"), ("execution", "execution.json"), ("save", "draft.md"), ("source-review", "review.txt")].map { kind, file -> Q.Evidence in
            let path = root.appendingPathComponent(file).path; let (hash, _) = try IntegrityCheck.hashFile(path, limit: 1_048_576)
            return .init(id: kind, kind: kind, path: path, sha256: hash, artifactHash: draft.documentHash)
        }
        let assessment = Q.Assessment(rubricID: rubric.id, rubricVersion: rubric.version, rubricHash: try Q.rubricHash(rubric), sourceManifestHash: rubric.sourceManifestHash, artifactHash: draft.documentHash, trialManifestHash: ResearchSectionWorkflow.hash(try Data(contentsOf: URL(fileURLWithPath: paths.trial))), reviewer: "Host fixture reviewer", evidenceIndex: evidence,
            ratings: [.init(criterionID: "quality", score: 4, evidence: ["source-review"])], gates: [.init(id: "code", status: .pass, evidence: ["code", "test", "execution"]), .init(id: "save", status: .pass, evidence: ["save"]), .init(id: "sources", status: .pass, evidence: ["source-review"])], units: units.map { .init(id: $0, status: .pass, evidence: ["source-review"]) })
        try write(assessment, URL(fileURLWithPath: paths.assessment))
        return Fixture(root: root, model: model, paths: paths, assessment: assessment, rubric: rubric, source: capture)
    }
    @MainActor func approve(_ fixture: Fixture, gaps: [ResearchRelease.GapReview] = []) async throws {
        let result = try await fixture.model.evaluateQualityRelease(fixture.paths)
        try await fixture.model.approveQualityRelease(expectedEvaluationHash: result.digest(), expectedWorkflowHash: try XCTUnwrap(fixture.model.qualityWorkflowHash), reviewer: "Fixture final reviewer", findings: "Reviewed all fixture sections, source coverage, indexed code and synthetic execution limitations.", gapReviews: gaps)
    }
    @MainActor func approvalHash(_ model: WorkbenchModel) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ResearchSectionWorkflow.hash(try encoder.encode(XCTUnwrap(model.session.researchCase?.releaseApproval)))
    }
    @MainActor func testFixtureReviewApprovalSaveReceiptAndNoOverwrite() async throws {
        let f = try fixture(); let evaluation = try await f.model.evaluateQualityRelease(f.paths)
        XCTAssertTrue(evaluation.fixtureOnly); XCTAssertTrue(evaluation.report.reviewRecordMeetsPolicy)
        XCTAssertNil(f.model.session.researchCase?.releaseApproval)
        try await approve(f)
        let output = f.root.appendingPathComponent("reviewed.md")
        let hash = try approvalHash(f.model)
        let receipt = try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash)
        XCTAssertEqual(try Data(contentsOf: output), try f.model.researchSectionsDraft().bytes)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual(record["fixtureOnly"] as? Bool, true); XCTAssertEqual(record["reviewRecordMeetsPolicy"] as? Bool, true)
        do { try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash); XCTFail("Overwrite accepted") } catch { }
        let restored = WorkbenchModel(stateDirectory: f.root.appendingPathComponent("state"))
        XCTAssertNotNil(restored.session.researchCase?.releaseApproval)
    }
    @MainActor func testUngradedAndFailedRecordsCannotBeApproved() async throws {
        var f = try fixture(); f.assessment.ratings[0].score = nil
        try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
        let result = try await f.model.evaluateQualityRelease(f.paths)
        XCTAssertFalse(result.report.reviewRecordMeetsPolicy); XCTAssertNil(result.report.score)
        do { try await approve(f); XCTFail("Ungraded review approved") } catch { }
        f.assessment.ratings[0].score = 4; f.assessment.gates[2].status = .fail
        try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
        do { try await approve(f); XCTFail("Failed gate approved") } catch { }
        XCTAssertNil(f.model.session.researchCase?.releaseApproval)
    }
    @MainActor func testChangedInputsRequireFreshExplicitApproval() async throws {
        let f = try fixture(); let result = try await f.model.evaluateQualityRelease(f.paths)
        let oldHash = try result.digest(); let workflow = try XCTUnwrap(f.model.qualityWorkflowHash)
        var assessment = f.assessment; assessment.reviewer = "Different fixture reviewer"
        try write(assessment, URL(fileURLWithPath: f.paths.assessment))
        do {
            try await f.model.approveQualityRelease(expectedEvaluationHash: oldHash, expectedWorkflowHash: workflow, reviewer: "Final reviewer", findings: "Reviewed all fixture sections and source evidence with explicit limitations.", gapReviews: [])
            XCTFail("Changed assessment reused old approval")
        } catch { }
        XCTAssertNil(f.model.session.researchCase?.releaseApproval)
    }
    @MainActor func testChangedPolicySourceEvidenceAndDocumentBlockRelease() async throws {
        let f = try fixture(); try await approve(f)
        let hash = try approvalHash(f.model); let output = f.root.appendingPathComponent("blocked.md")
        let policy = f.root.appendingPathComponent("policy.txt"); let bytes = try Data(contentsOf: policy)
        try Data("Changed policy".utf8).write(to: policy)
        do { try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash); XCTFail("Changed policy released") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); try bytes.write(to: policy)
        let code = f.root.appendingPathComponent("code.py"); let original = try Data(contentsOf: code)
        try Data("Different code".utf8).write(to: code)
        do { try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash); XCTFail("Changed evidence released") } catch { }
        try original.write(to: code)
        let sourceURL = URL(fileURLWithPath: f.source.original.canonicalPath)
        let sourceBytes = try Data(contentsOf: sourceURL)
        try Data("Changed source bytes".utf8).write(to: sourceURL)
        do { try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash); XCTFail("Changed source released") } catch { }
        try sourceBytes.write(to: sourceURL)
        f.model.session.notes = "Changed operator context"
        do { try await f.model.writeQualityRelease(to: output, expectedApprovalHash: hash); XCTFail("Stale sections released") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    @MainActor func testOmittedWindowsAndExtractionGapsNeedSeparateResolution() async throws {
        let f = try fixture(gap: true)
        do { try await approve(f); XCTFail("Extraction uncertainty ignored") } catch { }
        let gap = ResearchRelease.GapReview(source: f.source, evidenceID: "source-review", findings: "Inspected the original synthetic source and documented the simulated extraction limitation.")
        try await approve(f, gaps: [gap])
        var state = try XCTUnwrap(f.model.session.researchCase)
        state.sourcePlan?.windows.removeAll { $0.windowIndex == 1 }
        let evaluation = try XCTUnwrap(f.model.qualityEvaluation)
        XCTAssertThrowsError(try ResearchRelease.validateCoverage(state: state, evaluation: evaluation, reviews: [gap]))
    }
    @MainActor func testSharedOracleForgedTypesAndCodeNotInArtifactAreRefused() async throws {
        var f = try fixture()
        let path = f.root.appendingPathComponent("execution.json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        for patch: [String: Any] in [["oracleIsolation": "shared-process"], ["passed": 1], ["tests": true], ["subjectSHA256": String(repeating: "b", count: 64)]] {
            var record = original; for (key, value) in patch { record[key] = value }
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: path)
            f.assessment.evidenceIndex[2].sha256 = ResearchSectionWorkflow.hash(try Data(contentsOf: path))
            try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
            do { try await f.model.evaluateQualityRelease(f.paths); XCTFail("Invalid execution record accepted") } catch { }
        }
        try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: path)
        f.assessment.evidenceIndex[2].sha256 = ResearchSectionWorkflow.hash(try Data(contentsOf: path)); try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
        let evaluation = try await f.model.evaluateQualityRelease(f.paths)
        XCTAssertThrowsError(try ResearchRelease.validateExecutionRecords(evaluation, body: Data("Unrelated document without the indexed code".utf8)))
    }
    @MainActor func testWrongRubricAndReducedSourceInventoryAreRefused() async throws {
        let f = try fixture()
        var changed = f.rubric; changed.requiredUnits.removeLast()
        try write(changed, URL(fileURLWithPath: f.paths.rubric))
        do { try await f.model.evaluateQualityRelease(f.paths); XCTFail("Shortened rubric accepted") } catch { }
        try write(f.rubric, URL(fileURLWithPath: f.paths.rubric))
        f.model.session.researchCase?.sources = []
        do { try await f.model.evaluateQualityRelease(f.paths); XCTFail("Missing captured source accepted") } catch { }
    }
    func wampumTrial(_ f: Fixture) -> Q.Trial {
        Q.Trial(id: "supplied-record-test", caseID: f.rubric.id, condition: "Host-authored protocol records only; no inference outcome", authorArm: "wampum", state: "completed",
            configuration: ["model": .string("lukey03/Qwen3.5-9B-abliterated:latest"), "runtime": .string("Synthetic protocol-record fixture; no model called"), "tools": .array([]), "contextTokens": .number(8192), "outputTokens": .number(4096), "temperature": .number(0.2), "thinking": .bool(false), "auditSeed": .number(0), "auditRule": .string("host fixture"), "pairedTrialID": .string("fixture"), "plannedTrials": .number(1), "attemptID": .string("fixture"), "retryBudget": .number(0), "assistanceMode": .string("host-authored supplied-record tests")], assistance: ["All records fabricated transparently as host-authored fixtures; no Qwen ability is measured"])
    }
    @MainActor func testFixtureEvidenceCannotBeRelabeledAsARealModelRelease() async throws {
        var f = try fixture()
        try write(wampumTrial(f), URL(fileURLWithPath: f.paths.trial))
        f.assessment.trialManifestHash = ResearchSectionWorkflow.hash(try Data(contentsOf: URL(fileURLWithPath: f.paths.trial)))
        try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
        do { try await f.model.evaluateQualityRelease(f.paths); XCTFail("Fixture execution relabeled as a real model release") } catch { }
        XCTAssertNil(f.model.qualityEvaluation); XCTAssertNil(f.model.session.researchCase?.releaseApproval)
    }
    @MainActor func testSuppliedJournalConsistencyIsByteBoundNotExecutionAuthentication() throws {
        var f = try fixture()
        try write(wampumTrial(f), URL(fileURLWithPath: f.paths.trial))
        f.assessment.trialManifestHash = ResearchSectionWorkflow.hash(try Data(contentsOf: URL(fileURLWithPath: f.paths.trial)))
        try write(f.assessment, URL(fileURLWithPath: f.paths.assessment))
        let state = try XCTUnwrap(f.model.session.researchCase)
        let current = try f.model.currentResearchSections()
        var supplied = try ResearchSectionWorkflow(caseID: current.caseID, contractHash: current.contractHash, requiredSectionIDs: current.requiredSectionIDs, sources: current.sources)
        var responseURL: URL?
        for unit in current.requiredSectionIDs {
            var selected = state; selected.activeSourceUnit = unit
            let binding = try ResearchSectionRequest(state: selected, additionalSources: [f.model.sectionContextBinding()])
            let body = try XCTUnwrap(current.attempts.last(where: { $0.sectionID == unit })?.body)
            let root = f.root.appendingPathComponent("supplied-journal-" + unit)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let request = try JSONSerialization.data(withJSONObject: ["model": "lukey03/Qwen3.5-9B-abliterated:latest", "context": 8192, "researchFingerprint": selected.requestFingerprint(), "messages": [["role": "user", "content": "Host-authored supplied-record fixture, not a real request"]]], options: [.sortedKeys])
            let response = try JSONSerialization.data(withJSONObject: ["message": ["content": body], "done_reason": "stop", "eval_count": 40, "prompt_eval_count": 100], options: [.sortedKeys])
            let bindingData = try JSONEncoder().encode(binding)
            try request.write(to: root.appendingPathComponent("request.json")); try response.write(to: root.appendingPathComponent("response.json"))
            try bindingData.write(to: root.appendingPathComponent("section-request.json"))
            try Data(#"{"state":"responseSaved"}"#.utf8).write(to: root.appendingPathComponent("terminal.json"))
            try supplied.record(.init(sectionID: unit, caseID: current.caseID, contractHash: current.contractHash, body: body, stopReason: "stop", outputTokens: 40, inputTokens: 100, sources: binding.sources,
                provenance: .init(model: "lukey03/Qwen3.5-9B-abliterated:latest", requestID: root.path, requestSHA256: ResearchSectionWorkflow.hash(request), responseSHA256: ResearchSectionWorkflow.hash(response), bindingSHA256: ResearchSectionWorkflow.hash(bindingData))))
            responseURL = root.appendingPathComponent("response.json")
        }
        let evaluation = try ResearchRelease.evaluate(paths: f.paths, state: state, body: f.model.researchSectionsDraft().bytes)
        let pins = try ResearchRelease.validateSectionJournals(evaluation, workflow: supplied, state: state)
        XCTAssertEqual(pins.count, 8)
        // This checks supplied-record consistency only. The app separately rejects fixture execution evidence above.
        try Data("Changed journal".utf8).write(to: XCTUnwrap(responseURL))
        XCTAssertThrowsError(try ResearchRelease.validateSectionJournals(evaluation, workflow: supplied, state: state))
    }
    @MainActor func testNativeReviewFixtureExport() async throws {
        guard let output = ProcessInfo.processInfo.environment["WAMPUM_QUALITY_UI_FIXTURE"] else { throw XCTSkip("Opt-in retained synthetic native-review fixture.") }
        let f = try fixture(root: URL(fileURLWithPath: output))
        f.model.persist()
        try write(f.paths, f.root.appendingPathComponent("quality-paths.json"))
        let evaluation = try await f.model.evaluateQualityRelease(f.paths)
        XCTAssertTrue(evaluation.fixtureOnly)
    }
}
