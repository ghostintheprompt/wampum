import XCTest
@testable import WorkbenchCore

final class ResearchCoverageTests: XCTestCase {
    private func fixture(text: String, _ body: (ResearchCaseState, ResearchSourceCapture) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.md"); try Data(text.utf8).write(to: file)
        let capture = try ResearchSourceIngestor.capture(reviewed: ResearchSourceIngestor.review(url: file))
        let contract = ResearchCaseContract(id: "coverage", objective: "Review all required local material", roles: ["operator"], allowedActions: ["read"], requiredUnits: ["analysis", "verification"], rubricSHA256: String(repeating: "a", count: 64))
        try body(ResearchCaseState(contract: contract, sources: [capture]), capture)
    }
    func testExactTailSelectionExcludesFirstWindowAndPersists() throws {
        try fixture(text: "HEAD_MARKER " + String(repeating: "a", count: 2100) + "TAIL_MARKER") { original, capture in
            var state = original; let windows = try capture.windows(maxUTF8Bytes: 2048)
            var plan = try ResearchSourcePlan(contract: state.contract)
            plan.setSelected(true, unitID: "analysis", capture: capture, window: windows[1])
            state.sourcePlan = plan; state.activeSourceUnit = "analysis"
            let context = try state.requestContext()
            XCTAssertTrue(context.contains("TAIL_MARKER")); XCTAssertFalse(context.contains("HEAD_MARKER"))
            XCTAssertTrue(context.contains(windows[1].sha256))
            let report = try XCTUnwrap(plan.coverage(contract: state.contract, captures: state.sources).first)
            XCTAssertEqual(report.selectedWindowIndices, [1]); XCTAssertEqual(report.omittedWindowIndices, [0])
            XCTAssertEqual(report.selectedUTF8Bytes, windows[1].text.utf8.count)
            let restored = try JSONDecoder().decode(ResearchCaseState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(try restored.requestContext(), context)
            var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            legacyJSON.removeValue(forKey: "sourcePlan"); legacyJSON.removeValue(forKey: "activeSourceUnit")
            let legacy = try JSONDecoder().decode(ResearchCaseState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
            XCTAssertNil(legacy.sourcePlan); XCTAssertTrue(try legacy.requestContext().contains("HEAD_MARKER"))
            state.activeSourceUnit = "verification"
            XCTAssertFalse(try state.requestContext().contains("TAIL_MARKER"))
        }
    }
    func testCoverageAcrossUnitsUsesUniqueWindowsAndExplicitEmptySelection() throws {
        try fixture(text: String(repeating: "é", count: 2200)) { state, capture in
            let windows = try capture.windows(maxUTF8Bytes: 2048)
            var plan = try ResearchSourcePlan(contract: state.contract)
            plan.setSelected(true, unitID: "analysis", capture: capture, window: windows[0])
            plan.setSelected(true, unitID: "verification", capture: capture, window: windows[0])
            XCTAssertEqual(try plan.coverage(contract: state.contract, captures: state.sources).first?.selectedWindowIndices, [0])
            plan.setSelected(false, unitID: "analysis", capture: capture, window: windows[0])
            let empty = try XCTUnwrap(plan.coverage(contract: state.contract, captures: state.sources, unitID: "analysis").first)
            XCTAssertTrue(empty.selectedWindowIndices.isEmpty); XCTAssertEqual(empty.omittedWindowIndices.count, windows.count)
            XCTAssertEqual(try plan.coverage(contract: state.contract, captures: state.sources, unitID: "verification").first?.selectedUTF8Bytes, 2048)
        }
    }
    func testDuplicateWrongUnitChangedContractAndTamperedWindowAreRejected() throws {
        try fixture(text: "Evidence") { state, capture in
            let window = try XCTUnwrap(capture.windows(maxUTF8Bytes: 2048).first)
            let reference = ResearchWindowReference(unitID: "analysis", capture: capture, window: window)
            var plan = try ResearchSourcePlan(contract: state.contract, windows: [reference, reference])
            XCTAssertThrowsError(try plan.validate(contract: state.contract, captures: state.sources))
            plan.windows = [reference]
            var changed = state.contract; changed.objective = "Different case objective"
            XCTAssertThrowsError(try plan.validate(contract: changed, captures: state.sources))
            plan.windows = [.init(unitID: "invented", capture: capture, window: window)]
            XCTAssertThrowsError(try plan.validate(contract: state.contract, captures: state.sources))
            let forged = ResearchSourceWindow(index: 0, startUTF8: 0, endUTF8: window.endUTF8, text: "Fake", sha256: String(repeating: "b", count: 64))
            plan.windows = [.init(unitID: "analysis", capture: capture, window: forged)]
            XCTAssertThrowsError(try plan.validate(contract: state.contract, captures: state.sources))
        }
    }
    func testOversizedSelectionCannotBeSilentlyTruncatedAndCanBeEdited() throws {
        try fixture(text: String(repeating: "x", count: 40000)) { original, capture in
            var state = original
            state.sourcePlan = try ResearchSourcePlan(contract: state.contract, windows: capture.windows(maxUTF8Bytes: 2048).map { .init(unitID: "analysis", capture: capture, window: $0) })
            state.activeSourceUnit = "analysis"
            XCTAssertThrowsError(try state.requestContext())
            XCTAssertFalse(try state.sourceSelectionRevision().isEmpty)
            state.sourcePlan?.windows = []
            XCTAssertNoThrow(try state.requestContext())
        }
    }
    func testExtractionGapsRemainVisibleEvenWhenEveryTextWindowIsAllocated() throws {
        try fixture(text: "Extracted text") { original, capture in
            let limited = ResearchSourceCapture(original: capture.original, format: .pdf, extractedText: capture.extractedText,
                extractedTextSHA256: capture.extractedTextSHA256, warnings: ["Page 2 has no extractable text"], pages: [], fullDocumentTextCoverage: false)
            var state = original; state.sources = [limited]
            state.sourcePlan = try ResearchSourcePlan(contract: state.contract, windows: limited.windows(maxUTF8Bytes: 2048).map { .init(unitID: "analysis", capture: limited, window: $0) })
            state.activeSourceUnit = "analysis"
            let report = try XCTUnwrap(state.sourcePlan?.coverage(contract: state.contract, captures: state.sources).first)
            XCTAssertTrue(report.omittedWindowIndices.isEmpty); XCTAssertFalse(report.completeTextExtraction)
            XCTAssertTrue(try state.requestContext().contains("Page 2 has no extractable text"))
        }
    }
}
