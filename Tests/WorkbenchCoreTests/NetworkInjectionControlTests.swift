import XCTest
@testable import WorkbenchCore

final class NetworkInjectionControlTests: XCTestCase {
    private let scope = AuthorizedScope(["internal.client.test", "*.corp.client.test"])

    func testInScopeHostBuildsHostFilteredPlan() throws {
        let p = try NetworkInjectionControl.plan(targetHost: "internal.client.test", payload: "poisoned RAG doc", scope: scope)
        XCTAssertEqual(p.targetHost, "internal.client.test")
        XCTAssertTrue(p.guestDirective.contains("--only-host"))
        XCTAssertTrue(p.guestDirective.contains("internal.client.test"))
        XCTAssertEqual(p.receipt.tool, "net-inject")
        XCTAssertEqual(p.receipt.targets, ["internal.client.test"])
    }

    func testOutOfScopeHostFailsClosed() {
        XCTAssertThrowsError(try NetworkInjectionControl.plan(targetHost: "someone-elses.net", payload: "x", scope: scope))
        XCTAssertThrowsError(try NetworkInjectionControl.plan(targetHost: "internal.client.test", payload: "x", scope: AuthorizedScope([])))
    }

    func testEmptyAndNulPayloadRejected() {
        XCTAssertThrowsError(try NetworkInjectionControl.plan(targetHost: "internal.client.test", payload: "   ", scope: scope))
        XCTAssertThrowsError(try NetworkInjectionControl.plan(targetHost: "internal.client.test", payload: "a\u{0}b", scope: scope))
    }
}
