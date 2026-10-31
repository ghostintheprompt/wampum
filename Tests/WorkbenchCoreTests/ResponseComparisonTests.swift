import XCTest
@testable import WorkbenchCore

final class ResponseComparisonTests: XCTestCase {
    private func obs(_ label: String, _ authorized: Bool, _ status: Int, _ body: String) -> ResponseObservation {
        ResponseObservation(label: label, authorized: authorized, status: status,
                            bodySHA256: ResearchEvidence.hash(body), bodyBytes: body.utf8.count)
    }

    func testBrokenAccessControlWhenUnauthorizedGetsIdenticalBody() throws {
        let s = try ResponseComparison.evaluate([
            obs("owner", true, 200, "{\"ssn\":\"123\"}"),
            obs("attacker", false, 200, "{\"ssn\":\"123\"}")   // same bytes as owner
        ])
        XCTAssertEqual(s.classification, .brokenAccessControl)
        XCTAssertEqual(s.unauthorizedLabels, ["attacker"])
        XCTAssertTrue(s.present)
    }

    func testNotDeniedWhenUnauthorizedGetsDifferentSuccess() throws {
        let s = try ResponseComparison.evaluate([
            obs("owner", true, 200, "{\"ssn\":\"123\"}"),
            obs("attacker", false, 200, "{\"ssn\":\"999\"}")   // success but different body
        ])
        XCTAssertEqual(s.classification, .notDenied)
    }

    func testNoSignalWhenUnauthorizedDenied() throws {
        let s = try ResponseComparison.evaluate([
            obs("owner", true, 200, "data"),
            obs("attacker", false, 403, "forbidden"),
            obs("revoked", false, 401, "unauthorized")
        ])
        XCTAssertEqual(s.classification, .none)
        XCTAssertFalse(s.present)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try ResponseComparison.evaluate([obs("solo", true, 200, "x")]))              // need >= 2
        XCTAssertThrowsError(try ResponseComparison.evaluate([obs("a", true, 200, "x"), obs("a", false, 403, "y")])) // dup labels
        XCTAssertThrowsError(try ResponseComparison.evaluate([obs("a", true, 200, "x"), obs("b", true, 200, "x")]))  // no unauthorized identity
    }
}
