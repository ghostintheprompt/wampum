import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ResearchSectionsAppTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, WorkbenchModel, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        let contract = ResearchCaseContract(id: "sections-fixture", objective: "Assess local synthetic evidence", roles: ["operator"], allowedActions: ["read local fixtures"], requiredUnits: ["analysis", "verification"], rubricSHA256: String(repeating: "a", count: 64))
        let source = root.appendingPathComponent("source.md"); try Data("Synthetic observation with a bounded local verification record.".utf8).write(to: source)
        let capture = try ResearchSourceIngestor.capture(reviewed: ResearchSourceIngestor.review(url: source))
        var state = try ResearchCaseState(contract: contract, sources: [capture])
        state.sourcePlan = try ResearchSourcePlan(contract: contract)
        for unit in contract.requiredUnits {
            state.sourcePlan?.setSelected(true, unitID: unit, capture: capture, window: try capture.windows(maxUTF8Bytes: 2048)[0])
        }
        state.activeSourceUnit = "analysis"
        state.sectionInstructions = ["analysis": "Explain observations, limitations and alternative interpretations.", "verification": "Document independent checks and the limits of the evidence."]
        model.session.researchCase = state; model.session.model = "fixture-qwen"
        model.models = [try JSONDecoder().decode(LocalModel.self, from: Data(#"{"name":"fixture-qwen"}"#.utf8))]
        let receipt = root.appendingPathComponent("host-receipt.txt")
        try Data("Host-authored synthetic review evidence, not a model or production result.".utf8).write(to: receipt)
        return (root, model, receipt)
    }
    @MainActor private func record(_ model: WorkbenchModel, unit: String, stop: String = "stop") throws -> SectionGenerationAttempt {
        model.session.researchCase?.activeSourceUnit = unit
        let state = try XCTUnwrap(model.session.researchCase)
        let binding = try ResearchSectionRequest(state: state, additionalSources: [model.sectionContextBinding()])
        try model.recordResearchSection(binding, body: "# \(unit)\nThis host-authored fixture explains a bounded result and its evidence limitations.", stopReason: stop, outputTokens: 30, inputTokens: 100, model: "fixture-qwen", requestID: "host-fixture-no-model-call")
        return try XCTUnwrap(model.session.researchCase?.sectionWorkflow?.attempts.last)
    }
    @MainActor private func accept(_ model: WorkbenchModel, attempt: SectionGenerationAttempt, receipt: URL) throws {
        try model.reviewResearchSection(attemptID: attempt.id, expectedBinding: attempt.bindingHash, reviewer: "Fixture reviewer", explanation: "Reviewed the synthetic content, completeness and stated verification limits.", evidenceURL: receipt, decision: .approve)
    }
    @MainActor func testMissingRejectedAndTruncatedAttemptsCannotAssemble() throws {
        let (root, model, receipt) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try model.researchSectionsDraft())
        let partial = try record(model, unit: "analysis", stop: "length")
        XCTAssertThrowsError(try accept(model, attempt: partial, receipt: receipt))
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .incomplete)
        let replacement = try record(model, unit: "analysis")
        try model.reviewResearchSection(attemptID: replacement.id, expectedBinding: replacement.bindingHash, reviewer: "Fixture reviewer", explanation: "Rejected because substantive source coverage needs additional review.", evidenceURL: receipt, decision: .reject)
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .rejected)
        XCTAssertThrowsError(try model.researchSectionsDraft())
        XCTAssertEqual(model.session.researchCase?.sectionWorkflow?.attempts.count, 2)
    }
    @MainActor func testCompleteDraftPreservesOrderAndRechecksEvidenceAndContext() throws {
        let (root, model, receipt) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let analysis = try record(model, unit: "analysis"); try accept(model, attempt: analysis, receipt: receipt)
        let verification = try record(model, unit: "verification"); try accept(model, attempt: verification, receipt: receipt)
        let draft = try model.researchSectionsDraft()
        XCTAssertEqual(draft.status, .draft); XCTAssertNil(draft.qualityGate)
        let text = String(decoding: draft.bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# analysis")); XCTAssertTrue(text.contains("# verification"))
        let savedFile = root.appendingPathComponent("accepted-draft.md")
        let saveReceipt = try model.writeResearchSectionsDraft(to: savedFile, expectedCaseID: "sections-fixture", expectedDocumentHash: draft.documentHash)
        XCTAssertEqual(try Data(contentsOf: savedFile), draft.bytes)
        let receiptRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saveReceipt)) as? [String: Any])
        XCTAssertEqual(receiptRecord["qualityGateSatisfied"] as? Bool, false)
        XCTAssertEqual(receiptRecord["documentHash"] as? String, draft.documentHash)
        XCTAssertThrowsError(try model.writeResearchSectionsDraft(to: savedFile, expectedCaseID: "sections-fixture", expectedDocumentHash: draft.documentHash))
        XCTAssertThrowsError(try model.writeResearchSectionsDraft(to: root.appendingPathComponent("wrong-case.md"), expectedCaseID: "other-case", expectedDocumentHash: draft.documentHash))
        let restored = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        XCTAssertEqual(try restored.researchSectionsDraft().documentHash, draft.documentHash)
        try Data("Changed evidence".utf8).write(to: receipt)
        XCTAssertThrowsError(try restored.researchSectionsDraft())
        model.session.scope = "Changed operator scope"
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .stale)
        XCTAssertThrowsError(try model.researchSectionsDraft())
    }
    @MainActor func testOtherUnitRequirementEditsDoNotInvalidateAcceptedSibling() throws {
        let (root, model, receipt) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let attempt = try record(model, unit: "analysis"); try accept(model, attempt: attempt, receipt: receipt)
        model.session.researchCase?.sectionInstructions?["verification"] = "Additional verification detail for this separate unit."
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .accepted)
        model.session.researchCase?.sectionInstructions?["analysis"] = "Revised substantive analysis requirement."
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .stale)
        XCTAssertThrowsError(try accept(model, attempt: attempt, receipt: receipt))
    }
    @MainActor func testPreparationOnlyStagesAndContextChangeBlocksSend() throws {
        let (root, model, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.session.prompt = "Unsent user draft"
        XCTAssertThrowsError(try model.prepareResearchSection(unitID: "analysis", instructions: "Explain the evidence in detail."))
        XCTAssertEqual(model.session.prompt, "Unsent user draft")
        model.session.prompt = ""
        try model.prepareResearchSection(unitID: "analysis", instructions: "Explain the evidence in detail.")
        XCTAssertTrue(model.showRequestReview); XCTAssertFalse(model.busy); XCTAssertTrue(model.session.messages.isEmpty)
        XCTAssertEqual(model.pendingSectionRequest?.unitID, "analysis")
        XCTAssertTrue(model.requestPreview.contains("without an outer document fence"))
        model.session.notes = "Changed after the reviewed preview"
        model.sendReviewedRequest()
        XCTAssertFalse(model.busy); XCTAssertTrue(model.session.messages.isEmpty); XCTAssertFalse(model.showRequestReview)
        XCTAssertNotNil(model.error)
    }
    @MainActor func testRequirementsDraftPersistsWithoutApprovingOrInvalidatingSources() throws {
        let (root, model, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prior = try model.currentResearchSections().sources
        try model.saveSectionRequirementsDraft(unitID: "analysis", text: "Unfinished requirement draft")
        XCTAssertEqual(try model.store.load().researchCase?.sectionDrafts?["analysis"], "Unfinished requirement draft")
        XCTAssertEqual(try model.currentResearchSections().sources, prior)
        XCTAssertThrowsError(try model.saveSectionRequirementsDraft(unitID: "other-case", text: "wrong unit"))
    }
    @MainActor func testResponseIsPreservedWhenSourceChangesDuringGeneration() throws {
        let (root, model, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try XCTUnwrap(model.session.researchCase)
        let binding = try ResearchSectionRequest(state: state, additionalSources: [model.sectionContextBinding()])
        try Data("Changed after request".utf8).write(to: root.appendingPathComponent("source.md"))
        try model.recordResearchSection(binding, body: "Original returned response remains retained despite later source drift.", stopReason: "stop", outputTokens: 12, inputTokens: 50, model: "fixture-qwen", requestID: "host-fixture-no-model-call")
        XCTAssertEqual(model.session.researchCase?.sectionWorkflow?.attempts.count, 1)
        XCTAssertThrowsError(try model.currentResearchSections())
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try model.store.load().researchCase?.sectionWorkflow?.attempts.first?.body, "Original returned response remains retained despite later source drift.")
    }
    @MainActor func testMockTransportLinksRawResponseAndFrozenSectionBinding() async throws {
        let (root, original, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        original.persist()
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server,json,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  data=self.rfile.read(int(self.headers['Content-Length']))
  with open(sys.argv[1],'wb') as f: f.write(data)
  answer={'message':{'content':'# Analysis\nHost-authored mock response with explicit verification limits.'},'done_reason':'length','prompt_eval_count':120,'eval_count':18}
  body=json.dumps(answer).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*args): pass
s=http.server.HTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
"""#, root.appendingPathComponent("received-request.json").path]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate() }
        var line = Data(); while !line.contains(10) { line.append(try XCTUnwrap(pipe.fileHandleForReading.read(upToCount: 1))) }
        let port = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"), ollamaBase: try XCTUnwrap(URL(string: "http://127.0.0.1:" + port)))
        model.models = original.models
        try model.prepareResearchSection(unitID: "analysis", instructions: "Explain the exact selected synthetic source and limitations.")
        let binding = try XCTUnwrap(model.pendingSectionRequest)
        model.sendReviewedRequest()
        for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
        let attempt = try XCTUnwrap(model.session.researchCase?.sectionWorkflow?.attempts.first)
        XCTAssertEqual(attempt.sources, binding.sources); XCTAssertEqual(attempt.stopReason, "length")
        XCTAssertEqual(try model.currentResearchSections().state(for: "analysis"), .incomplete)
        let journal = URL(fileURLWithPath: attempt.provenance.requestID)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal.appendingPathComponent("response.json"))) as? [String: Any])
        XCTAssertEqual((raw["message"] as? [String: String])?["content"], attempt.body)
        let frozen = try JSONDecoder().decode(ResearchSectionRequest.self, from: Data(contentsOf: journal.appendingPathComponent("section-request.json")))
        XCTAssertEqual(frozen.sources, binding.sources); XCTAssertEqual(frozen.unitID, "analysis")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.appendingPathComponent("terminal.json").path))
    }

}
