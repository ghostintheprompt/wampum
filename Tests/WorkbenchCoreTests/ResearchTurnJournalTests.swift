import XCTest
@testable import WorkbenchCore

final class ResearchTurnJournalTests: XCTestCase {
    func testRequestAndRawResponseArePreservedWithoutOverwrite() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ResearchTurnJournal(root: root, messages: [["role":"user", "content":"reviewed request"]], model: "fixture", context: 8192, thinking: false, supportsThinking: false, fingerprint: String(repeating: "a", count: 64))
        let request = try Data(contentsOf: journal.directory.appendingPathComponent("request.json"))
        XCTAssertTrue(String(decoding: request, as: UTF8.self).contains("reviewed request"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent("terminal.json").path))
        let raw = Data("{\"message\":{\"content\":\"partial\"},\"done_reason\":\"length\"}".utf8)
        try journal.recordRawResponse(raw)
        XCTAssertThrowsError(try journal.recordRawResponse(Data("forged replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("response.json")), raw)
        try journal.recordTerminal("responseSaved", detail: "length; incomplete")
        XCTAssertThrowsError(try journal.recordTerminal("responseSaved", detail: "replacement"))
        XCTAssertThrowsError(try journal.recordTerminal("verified", detail: "unsupported claim"))
    }
    func testFrozenSectionMetadataIsSavedWithoutOverwrite() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contract = ResearchCaseContract(id: "journal-fixture", objective: "Review a synthetic case", roles: ["operator"], allowedActions: ["read"], requiredUnits: ["analysis"], rubricSHA256: String(repeating: "a", count: 64))
        var state = try ResearchCaseState(contract: contract)
        state.sourcePlan = try ResearchSourcePlan(contract: contract); state.activeSourceUnit = "analysis"
        state.sectionInstructions = ["analysis": "Explain the evidence and its actual limitations."]
        let binding = try ResearchSectionRequest(state: state)
        let journal = try ResearchTurnJournal(root: root, messages: [], model: "fixture", context: 8192, thinking: false, supportsThinking: false, fingerprint: state.requestFingerprint())
        try journal.recordSectionBinding(binding)
        XCTAssertThrowsError(try journal.recordSectionBinding(binding))
        let restored = try JSONDecoder().decode(ResearchSectionRequest.self, from: Data(contentsOf: journal.directory.appendingPathComponent("section-request.json")))
        XCTAssertEqual(restored.unitID, "analysis"); XCTAssertEqual(restored.sources, binding.sources)
    }

}
