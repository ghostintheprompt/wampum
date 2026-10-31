import XCTest
@testable import WorkbenchCore

final class DetectionProfileTests: XCTestCase {
    private func run(env: String, version: Int = 1, reactions: [String: String], at: Date) -> DetectionRun {
        DetectionRun(profileName: "waf-coverage", profileVersion: version, environment: env, at: at,
                     baselineReaction: .allowed, reactions: reactions, evidenceIDs: [])
    }

    func testSameEnvironmentChangeIsRegression() throws {
        let t0 = Date(); let t1 = t0.addingTimeInterval(86400)
        let prior = run(env: "prod", reactions: ["baseline": "allowed", "ua-bot": "blocked"], at: t0)
        let new = run(env: "prod", reactions: ["baseline": "allowed", "ua-bot": "allowed"], at: t1)
        let r = try DetectionComparison.compare(prior: prior, new: new)
        XCTAssertTrue(r.hasChanges)
        XCTAssertTrue(r.sameEnvironment)
        XCTAssertEqual(r.kind, "regression/drift")
        XCTAssertEqual(r.changes.count, 1)
        XCTAssertEqual(r.changes.first?.label, "ua-bot")
        XCTAssertEqual(r.changes.first?.from, "blocked")
        XCTAssertEqual(r.changes.first?.to, "allowed")
        XCTAssertTrue(r.detail.contains("LEAD"))
    }

    func testDifferentEnvironmentChangeIsEnvironmentDifference() throws {
        let prior = run(env: "staging", reactions: ["ua-bot": "allowed"], at: Date())
        let new = run(env: "prod", reactions: ["ua-bot": "blocked"], at: Date())
        let r = try DetectionComparison.compare(prior: prior, new: new)
        XCTAssertFalse(r.sameEnvironment)
        XCTAssertEqual(r.kind, "environment-difference")
    }

    func testVersionMismatchIsFlagged() throws {
        let prior = run(env: "prod", version: 1, reactions: ["ua-bot": "blocked"], at: Date())
        let new = run(env: "prod", version: 2, reactions: ["ua-bot": "allowed"], at: Date())
        let r = try DetectionComparison.compare(prior: prior, new: new)
        XCTAssertFalse(r.versionMatch)
        XCTAssertTrue(r.detail.contains("profile version differs"))
    }

    func testNoChangeWhenIdentical() throws {
        let prior = run(env: "prod", reactions: ["baseline": "allowed", "ua-bot": "blocked"], at: Date())
        let new = run(env: "prod", reactions: ["baseline": "allowed", "ua-bot": "blocked"], at: Date())
        let r = try DetectionComparison.compare(prior: prior, new: new)
        XCTAssertFalse(r.hasChanges)
    }

    func testDifferentProfilesCannotBeCompared() {
        let a = run(env: "prod", reactions: [:], at: Date())
        let b = DetectionRun(profileName: "other", profileVersion: 1, environment: "prod", at: Date(),
                             baselineReaction: .allowed, reactions: [:], evidenceIDs: [])
        XCTAssertThrowsError(try DetectionComparison.compare(prior: a, new: b))
    }

    func testStoreRecordsRunsAndReturnsPriorPerEngagement() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DetectionProfileStore(root: root)
        let profile = DetectionProfile(name: "waf-coverage", method: "GET", url: "https://app.a.test/x",
                                       baseline: RequestVariation(label: "baseline"),
                                       variations: [RequestVariation(label: "ua-bot")])
        let r1 = run(env: "prod", reactions: ["ua-bot": "blocked"], at: Date())
        let prior1 = try store.record(profile: profile, run: r1, caseID: "client-a")
        XCTAssertNil(prior1, "first run has no prior")
        let r2 = run(env: "prod", reactions: ["ua-bot": "allowed"], at: Date().addingTimeInterval(10))
        let prior2 = try store.record(profile: profile, run: r2, caseID: "client-a")
        XCTAssertEqual(prior2?.reactions["ua-bot"], "blocked", "second run sees the first as prior")

        // A different engagement's store is separate.
        let other = try store.load("client-b")
        XCTAssertTrue(other.isEmpty)
        let a = try store.load("client-a")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.first?.runs.count, 2)
    }
}
