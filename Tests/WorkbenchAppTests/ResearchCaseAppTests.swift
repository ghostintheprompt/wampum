import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ResearchCaseAppTests: XCTestCase {
    @MainActor func fixture() throws -> (URL, WorkbenchModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        model.models = [try JSONDecoder().decode(LocalModel.self, from: Data(#"{"name":"fixture-qwen"}"#.utf8))]
        model.session.model = "fixture-qwen"; model.session.prompt = "Review the evidence"
        let contract = ResearchCaseContract(id: "fixture", objective: "Assess local evidence", roles: ["operator"], allowedActions: ["read"], requiredUnits: ["report"], rubricSHA256: String(repeating: "a", count: 64))
        model.session.researchCase = try .init(contract: contract)
        return (root, model)
    }
    @MainActor func testChangedContractAfterPreviewCannotSendOrConsumeDraft() throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.send(); XCTAssertTrue(model.showRequestReview)
        XCTAssertTrue(model.requestPreview.contains("OPERATOR CASE CONTRACT"))
        model.session.researchCase?.contract.objective = "Changed objective"
        model.sendReviewedRequest()
        XCTAssertFalse(model.busy); XCTAssertTrue(model.session.messages.isEmpty)
        XCTAssertEqual(model.session.prompt, "Review the evidence")
        XCTAssertNotNil(model.error); XCTAssertFalse(model.showRequestReview)
    }
    @MainActor func testChangedBrowserObservationAndGoalRequireNewPreview() throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = model.browser; browser.connected = true; browser.snapshotFresh = true
        browser.snapshot = "Page A"; browser.goal = "Inspect local fixture"; model.capabilities = ["tools"]
        browser.preparePlan(model: model); XCTAssertTrue(browser.showPlanReview, browser.diagnostics)
        browser.snapshot = "Page B"; browser.sendPlan(model: model)
        XCTAssertFalse(browser.busy); XCTAssertFalse(browser.showPlanReview)
        XCTAssertTrue(browser.diagnostics.contains("changed"))
        browser.preparePlan(model: model); XCTAssertTrue(browser.showPlanReview)
        browser.goal = "Different goal"; browser.sendPlan(model: model)
        XCTAssertFalse(browser.busy); XCTAssertTrue(browser.receipts.isEmpty)
    }
    @MainActor func testReplacementArchivesOldContextAndRefusesActiveBrowser() throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.session.messages = [ChatMessage(role: "assistant", content: "OLD_CASE_CLAIM")]
        model.session.notes = "Old notes"; model.session.scope = "Old scope"; model.includeEditor = true
        var contract = try XCTUnwrap(model.session.researchCase?.contract); contract.id = "new-case"
        let replacement = try ResearchCaseState(contract: contract)
        model.browser.connected = true
        XCTAssertThrowsError(try model.replaceResearchCase(replacement))
        XCTAssertEqual(model.session.researchCase?.contract.id, "fixture")
        model.browser.connected = false; model.controller.enabled = true
        XCTAssertThrowsError(try model.replaceResearchCase(replacement))
        model.controller.enabled = false; try model.replaceResearchCase(replacement)
        XCTAssertTrue(model.session.messages.isEmpty); XCTAssertEqual(model.session.notes, "")
        XCTAssertEqual(model.session.scope, ""); XCTAssertFalse(model.includeEditor)
        let checkpointDirectory = model.store.directory.appendingPathComponent("checkpoints")
        let checkpoints = try FileManager.default.contentsOfDirectory(at: checkpointDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(try checkpoints.contains { try String(contentsOf: $0).contains("OLD_CASE_CLAIM") })
        let restored = try model.store.load(); XCTAssertEqual(restored.researchCase?.contract.id, "new-case")
        XCTAssertTrue(restored.messages.isEmpty)
    }
    @MainActor func testCasePersistsAcrossAppModelRestart() throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.persist()
        let restored = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        XCTAssertEqual(restored.session.researchCase?.contract.id, "fixture")
        XCTAssertEqual(try restored.session.researchCase?.requestFingerprint(), try model.session.researchCase?.requestFingerprint())
    }
}

extension ResearchCaseAppTests {
    @MainActor func testLiveApprovedMemoryAfterRestart() async throws {
        guard let location = ProcessInfo.processInfo.environment["WAMPUM_CASE_PILOT"] else { throw XCTSkip("Opt-in installed Qwen case-memory pilot.") }
        let root = URL(fileURLWithPath: location)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw WorkbenchError.invalid("Pilot output already exists; refusing overwrite.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let modelName = "lukey03/Qwen3.5-9B-abliterated:latest"
        let contract = ResearchCaseContract(id: "memory-pilot", objective: "Recall only an explicitly approved local fixture identifier", roles: ["operator", "local assistant"], allowedActions: ["read the supplied fixture; no tools"], requiredUnits: ["exact identifier response"], rubricSHA256: String(repeating: "a", count: 64))
        let nonce = "CASE-" + UUID().uuidString
        let evidenceURL = root.appendingPathComponent("operator-note.txt")
        try Data(("Approved fixture identifier: " + nonce).utf8).write(to: evidenceURL)
        let contractHash = try contract.digest()
        var ledger = ResearchEvidence.Ledger(caseID: contract.id, contractHash: contractHash)
        try ledger.addEvidence(.pin(id: "operator-note", caseID: contract.id, contractHash: contractHash, kind: .operatorNote, path: evidenceURL.path))
        let fact = ResearchEvidence.Fact(id: "identifier", content: "The fixture identifier is " + nonce, meaning: .reported, evidenceIDs: ["operator-note"])
        try ledger.propose(fact)
        try ledger.recordOperatorReview(.init(factID: fact.id, contentHash: fact.contentHash, evidenceIDs: fact.evidenceIDs, state: .approved, reviewer: "Host-authored pilot fixture"))
        let model = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        model.session.researchCase = try ResearchCaseState(contract: contract, ledger: ledger)
        model.session.model = modelName; model.session.context = 8192; model.persist()
        let restored = WorkbenchModel(stateDirectory: root.appendingPathComponent("state"))
        restored.models = try await restored.client.models()
        XCTAssertTrue(restored.models.contains { $0.name == modelName })
        let info = try await restored.client.show(modelName); restored.capabilities = info.capabilities ?? []
        try JSONSerialization.data(withJSONObject: ["installedTags": restored.models.map(\.name), "selectedModel": modelName, "capabilities": restored.capabilities], options: [.sortedKeys]).write(to: root.appendingPathComponent("model-discovery.json"))
        restored.session.prompt = "Return only the exact fixture identifier from the approved memory JSON. No explanation or code. If it is missing return UNKNOWN."
        restored.send(); XCTAssertTrue(restored.showRequestReview, restored.error ?? "No preview")
        try Data(restored.requestPreview.utf8).write(to: root.appendingPathComponent("request-preview.txt"))
        restored.sendReviewedRequest()
        for _ in 0..<2400 { if !restored.busy { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(restored.busy, "Pilot timed out; retained state is not acceptance")
        let reply = restored.session.messages.last(where: { $0.role == "assistant" })
        let exact = reply?.content.trimmingCharacters(in: .whitespacesAndNewlines) == nonce
        try JSONSerialization.data(withJSONObject: ["exactRecall": exact, "stopReason": reply?.stopReason ?? "unknown", "error": restored.error ?? "", "assurance": "Host-approved durable memory assistance after app-model restart. Not unaided recall, full-document acceptance or native UI verification."], options: [.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        XCTAssertTrue(exact, reply?.content ?? restored.error ?? "No answer")
        XCTAssertEqual(reply?.stopReason, "stop")
    }
}
