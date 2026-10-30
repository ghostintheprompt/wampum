import XCTest
@testable import WorkbenchCore

final class WirelessScopeTests: XCTestCase {
    private func scope() -> WirelessScope {
        WirelessScope([WirelessTarget(bssid: "aa-bb-cc-dd-ee-ff", channel: 36, essid: "ClientCorp"),
                       WirelessTarget(bssid: "11:22:33:44:55:66", channel: 6)])
    }

    func testNormalizationAndValidity() {
        XCTAssertEqual(WirelessScope.normalize("aa-bb-cc-dd-ee-ff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertTrue(WirelessScope.isValidBSSID("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(WirelessScope.isValidBSSID("ZZ:bb:cc:dd:ee:ff"))
        XCTAssertFalse(WirelessScope.isValidBSSID("aa:bb:cc:dd:ee"))
        XCTAssertTrue(WirelessScope.isValidChannel(36))
        XCTAssertFalse(WirelessScope.isValidChannel(0))
    }

    func testEmptyScopeFailsClosed() {
        XCTAssertThrowsError(try WirelessScope([]).authorize(bssid: "AA:BB:CC:DD:EE:FF")) { error in
            XCTAssertTrue((error as? WorkbenchError)?.errorDescription?.contains("No wireless scope") == true)
        }
    }

    func testAuthorizeAndSelect() throws {
        let s = scope()
        XCTAssertEqual(try s.authorize(bssid: "AA:BB:CC:DD:EE:FF"), "AA:BB:CC:DD:EE:FF")
        XCTAssertThrowsError(try s.authorize(bssid: "99:99:99:99:99:99"))
        let selected = try s.select(["aa:bb:cc:dd:ee:ff"])
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.channel, 36)
        XCTAssertThrowsError(try s.select(["99:99:99:99:99:99"]))
    }

    func testContractCarriesWirelessScopeAndLegacyDigestUnchanged() throws {
        let base = ResearchCaseContract(id: "w1", objective: "o", roles: ["operator"], allowedActions: ["capture"], requiredUnits: ["u1"], rubricSHA256: String(repeating: "a", count: 64))
        let encoded = String(decoding: try JSONEncoder().encode(base), as: UTF8.self)
        XCTAssertFalse(encoded.contains("wirelessScope"))
        // Adding a wireless scope changes the digest and round-trips.
        var scoped = base; scoped.wirelessScope = [WirelessTarget(bssid: "AA:BB:CC:DD:EE:FF", channel: 36)]
        XCTAssertNotEqual(try base.digest(), try scoped.digest())
        let round = try JSONDecoder().decode(ResearchCaseContract.self, from: try JSONEncoder().encode(scoped))
        XCTAssertEqual(round.wirelessScope.first?.bssid, "AA:BB:CC:DD:EE:FF")
        XCTAssertNoThrow(try round.wireless.authorize(bssid: "aa:bb:cc:dd:ee:ff"))
    }

    func testContractRejectsInvalidWirelessTarget() {
        var bad = ResearchCaseContract(id: "w2", objective: "o", roles: ["operator"], allowedActions: ["capture"], requiredUnits: ["u1"], rubricSHA256: String(repeating: "a", count: 64))
        bad.wirelessScope = [WirelessTarget(bssid: "nope", channel: 6)]
        XCTAssertThrowsError(try bad.digest())
    }
}
