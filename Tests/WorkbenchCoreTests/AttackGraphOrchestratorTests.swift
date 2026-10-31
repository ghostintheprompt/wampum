import XCTest
@testable import WorkbenchCore

final class AttackGraphOrchestratorTests: XCTestCase {
    private func sig(_ technique: String, _ crossed: Bool) -> AIRedTeam.Signal {
        AIRedTeam.Signal(technique: technique, crossed: crossed, detail: "\(technique) probe", markers: [])
    }

    func testBuildSetsSuccessfulTechniquesFromMixedSignals() {
        let report = AttackGraphOrchestrator.build(from: [
            sig("direct-injection", false),
            sig("token-fragmentation", true),
            sig("rag-contamination", false),
            sig("memory-poisoning", true),
        ])
        XCTAssertEqual(report.nodes.count, 4)
        XCTAssertEqual(report.successfulTechniques, ["token-fragmentation", "memory-poisoning"])
        XCTAssertTrue(report.anyCrossing)
    }

    func testAnyCrossingFalseWhenNoneCrossed() {
        let report = AttackGraphOrchestrator.build(from: [
            sig("direct-injection", false),
            sig("rag-contamination", false),
        ])
        XCTAssertFalse(report.anyCrossing)
        XCTAssertTrue(report.successfulTechniques.isEmpty)
    }

    func testNextMutationSuggestionReturnsUncrossedThenNil() {
        let all = ["direct-injection", "token-fragmentation", "rag-contamination"]

        let partial = AttackGraphOrchestrator.build(from: [
            sig("direct-injection", true),
            sig("token-fragmentation", false),
        ])
        XCTAssertEqual(AttackGraphOrchestrator.nextMutationSuggestion(partial, allTechniques: all),
                       "token-fragmentation")

        let allCrossed = AttackGraphOrchestrator.build(from: all.map { sig($0, true) })
        XCTAssertNil(AttackGraphOrchestrator.nextMutationSuggestion(allCrossed, allTechniques: all))
    }
}
