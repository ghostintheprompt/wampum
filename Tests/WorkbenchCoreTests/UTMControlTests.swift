import XCTest
@testable import WorkbenchCore

final class UTMControlTests: XCTestCase {
    private let scope = WirelessScope([WirelessTarget(bssid: "AA:BB:CC:DD:EE:FF", channel: 36, essid: "ClientCorp"),
                                       WirelessTarget(bssid: "11:22:33:44:55:66", channel: 6)])

    func testArgvConstruction() throws {
        XCTAssertEqual(try UTMControl.argv(vm: "Kali", .start), ["start", "--hide", "Kali"])
        XCTAssertEqual(try UTMControl.argv(vm: "Kali", .ipAddress), ["ip-address", "--hide", "Kali"])
        XCTAssertEqual(try UTMControl.argv(vm: "Kali", .exec(cmd: "id")), ["exec", "--hide", "Kali", "--cmd", "id"])
        XCTAssertEqual(try UTMControl.argv(vm: "Kali", .filePush(guestPath: "/tmp/scope.json")), ["file", "push", "--hide", "Kali", "/tmp/scope.json"])
        XCTAssertEqual(try UTMControl.argv(vm: "Kali", .filePull(guestPath: "/tmp/manifest.json")), ["file", "pull", "--hide", "Kali", "/tmp/manifest.json"])
    }

    func testArgvRejectsUnsafeInput() {
        XCTAssertThrowsError(try UTMControl.argv(vm: "", .start))
        XCTAssertThrowsError(try UTMControl.argv(vm: "Kali", .filePush(guestPath: "relative/path")))
        XCTAssertThrowsError(try UTMControl.argv(vm: "Kali", .filePull(guestPath: "/tmp/../etc/shadow")))
    }

    func testGuestScopeDataEnforcesScope() throws {
        let data = try UTMControl.guestScopeData(engagementID: "eng-1", operator: "MDRN Red Team Sec",
                                                 authorization: "Written RoE on file", durationSeconds: 120,
                                                 scope: scope, select: ["aa:bb:cc:dd:ee:ff"])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["engagement_id"] as? String, "eng-1")
        let targets = obj["targets"] as! [[String: Any]]
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?["bssid"] as? String, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(targets.first?["channel"] as? Int, 36)
        // Out-of-scope / empty selection fails closed.
        XCTAssertThrowsError(try UTMControl.guestScopeData(engagementID: "eng-1", operator: "op", authorization: "x", durationSeconds: 120, scope: scope, select: ["99:99:99:99:99:99"]))
        XCTAssertThrowsError(try UTMControl.guestScopeData(engagementID: "eng-1", operator: "op", authorization: "x", durationSeconds: 120, scope: scope, select: []))
        XCTAssertThrowsError(try UTMControl.guestScopeData(engagementID: "", operator: "op", authorization: "x", durationSeconds: 120, scope: scope, select: ["AA:BB:CC:DD:EE:FF"]))
    }

    func testManifestVerificationFailsClosedOnOutOfScope() throws {
        let good = """
        {"engagement_id":"eng-1","targets":[{"bssid":"AA:BB:CC:DD:EE:FF","channel":36}],
         "files":[{"path":"cap-01-AABBCCDDEEFF-01.cap","sha256":"\(String(repeating: "a", count: 64))","bytes":2048}]}
        """
        let files = try UTMControl.verify(manifest: Data(good.utf8), scope: scope, engagementID: "eng-1")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.bytes, 2048)

        // Engagement mismatch.
        XCTAssertThrowsError(try UTMControl.verify(manifest: Data(good.utf8), scope: scope, engagementID: "other"))

        // An out-of-scope BSSID in the manifest is rejected wholesale.
        let outOfScope = """
        {"engagement_id":"eng-1","targets":[{"bssid":"DE:AD:BE:EF:00:00","channel":1}],
         "files":[{"path":"x.cap","sha256":"\(String(repeating: "b", count: 64))","bytes":10}]}
        """
        XCTAssertThrowsError(try UTMControl.verify(manifest: Data(outOfScope.utf8), scope: scope, engagementID: "eng-1")) { error in
            XCTAssertTrue((error as? WorkbenchError)?.errorDescription?.contains("out-of-scope capture") == true)
        }

        // Malformed file entry (path traversal) is rejected.
        let badFile = """
        {"engagement_id":"eng-1","targets":[{"bssid":"AA:BB:CC:DD:EE:FF","channel":36}],
         "files":[{"path":"../escape.cap","sha256":"\(String(repeating: "a", count: 64))","bytes":1}]}
        """
        XCTAssertThrowsError(try UTMControl.verify(manifest: Data(badFile.utf8), scope: scope, engagementID: "eng-1"))
    }
}
