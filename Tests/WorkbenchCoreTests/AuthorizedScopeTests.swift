import XCTest
@testable import WorkbenchCore

final class AuthorizedScopeTests: XCTestCase {
    func testEmptyScopeAuthorizesNothing() {
        let scope = AuthorizedScope([])
        XCTAssertTrue(scope.isEmpty)
        XCTAssertThrowsError(try scope.authorize(URL(string: "https://example.com/path")!)) { error in
            XCTAssertTrue((error as? WorkbenchError)?.errorDescription?.contains("No authorized scope") == true)
        }
    }
    func testExactHostMatchingIsHostOnly() throws {
        let scope = AuthorizedScope(["api.example.com"])
        XCTAssertEqual(try scope.authorize(URL(string: "https://api.example.com/v1/users?token=secret")!), "api.example.com")
        // A different host, a parent, and a look-alike are all rejected.
        for bad in ["https://example.com/", "https://web.example.com/", "https://api.example.com.evil.test/", "https://evilapi.example.com/"] {
            XCTAssertThrowsError(try scope.authorize(URL(string: bad)!), bad)
        }
    }
    func testSubdomainWildcardExcludesApex() throws {
        let scope = AuthorizedScope(["*.example.com"])
        XCTAssertNoThrow(try scope.authorize(URL(string: "https://a.example.com/")!))
        XCTAssertNoThrow(try scope.authorize(URL(string: "https://a.b.example.com/")!))
        XCTAssertThrowsError(try scope.authorize(URL(string: "https://example.com/")!))
        XCTAssertThrowsError(try scope.authorize(URL(string: "https://example.com.evil.test/")!))
    }
    func testDotWildcardIncludesApex() throws {
        let scope = AuthorizedScope([".example.com"])
        XCTAssertNoThrow(try scope.authorize(URL(string: "https://example.com/")!))
        XCTAssertNoThrow(try scope.authorize(URL(string: "https://deep.sub.example.com/")!))
        XCTAssertThrowsError(try scope.authorize(URL(string: "https://notexample.com/")!))
    }
    func testNormalizationToleratesPastedURLAndPortAndCase() {
        let scope = AuthorizedScope(["HTTPS://API.Example.com:443/admin", " api.example.com "])
        // Both inputs normalize to the same host and de-duplicate.
        XCTAssertEqual(scope.entries, ["api.example.com"])
        XCTAssertTrue(scope.matches(host: "api.example.com"))
    }
    func testInvalidEntriesAreRejectedByValidate() {
        XCTAssertThrowsError(try AuthorizedScope(["no-dot-host"]).validate())
        XCTAssertThrowsError(try AuthorizedScope(["bad_underscore.example.com"]).validate())
        XCTAssertThrowsError(try AuthorizedScope(["-leadinghyphen.example.com"]).validate())
        XCTAssertNoThrow(try AuthorizedScope(["ok.example.com", "*.wild.example.com", ".apex.example.com"]).validate())
    }
    func testContractCarriesScopeAndLegacyDigestIsUnchanged() throws {
        let base = ResearchCaseContract(id: "c1", objective: "o", roles: ["operator"], allowedActions: ["read"], requiredUnits: ["u1"], rubricSHA256: String(repeating: "a", count: 64))
        // A legacy contract (no scope) must encode without the key and keep its old digest.
        let encoded = String(decoding: try JSONEncoder().encode(base), as: UTF8.self)
        XCTAssertFalse(encoded.contains("authorizedScope"))
        let roundTrip = try JSONDecoder().decode(ResearchCaseContract.self, from: Data(encoded.utf8))
        XCTAssertEqual(try base.digest(), try roundTrip.digest())
        XCTAssertTrue(roundTrip.authorizedScope.isEmpty)
        // Adding scope changes the digest and is preserved across a round trip.
        var scoped = base; scoped.authorizedScope = ["*.target.test"]
        XCTAssertNotEqual(try base.digest(), try scoped.digest())
        let scopedRound = try JSONDecoder().decode(ResearchCaseContract.self, from: try JSONEncoder().encode(scoped))
        XCTAssertEqual(scopedRound.authorizedScope, ["*.target.test"])
        XCTAssertNoThrow(try scopedRound.scope.authorize(URL(string: "https://app.target.test/")!))
    }
    func testContractRejectsInvalidScopeEntry() {
        var bad = ResearchCaseContract(id: "c2", objective: "o", roles: ["operator"], allowedActions: ["read"], requiredUnits: ["u1"], rubricSHA256: String(repeating: "a", count: 64))
        bad.authorizedScope = ["not a host"]
        XCTAssertThrowsError(try bad.digest())
    }
}
