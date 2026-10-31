import XCTest
@testable import WorkbenchCore

final class BolaSweepTests: XCTestCase {
    func testCrossTenantReadIsFlagged() throws {
        // owner-0001 owns 0001; attacker owns nothing. Attacker reads 0001 (owner-identical) and 0002.
        let cells = [
            BolaCell(identity: "owner-0001", objectID: "0001", authorized: true, status: 200, bodySHA256: "A1", bodyBytes: 10),
            BolaCell(identity: "owner-0001", objectID: "0002", authorized: false, status: 403, bodySHA256: "x", bodyBytes: 0),
            BolaCell(identity: "attacker", objectID: "0001", authorized: false, status: 200, bodySHA256: "A1", bodyBytes: 10), // owner-identical
            BolaCell(identity: "attacker", objectID: "0002", authorized: false, status: 200, bodySHA256: "B2", bodyBytes: 12), // success, no owner succeeded
        ]
        let s = try BolaSweep.evaluate(cells)
        XCTAssertTrue(s.present)
        XCTAssertEqual(s.crossTenant.count, 2)
        let hit0001 = s.crossTenant.first { $0.objectID == "0001" }
        XCTAssertEqual(hit0001?.identity, "attacker")
        XCTAssertTrue(hit0001?.byteIdenticalToOwner ?? false, "attacker got the exact bytes owner-0001 received")
        XCTAssertTrue(s.detail.contains("owner-identical"))
    }

    func testNoCrossTenantWhenEachReadsOnlyOwned() throws {
        let cells = [
            BolaCell(identity: "owner-0001", objectID: "0001", authorized: true, status: 200, bodySHA256: "A1", bodyBytes: 10),
            BolaCell(identity: "owner-0001", objectID: "0002", authorized: false, status: 403, bodySHA256: "x", bodyBytes: 0),
            BolaCell(identity: "owner-0002", objectID: "0001", authorized: false, status: 403, bodySHA256: "x", bodyBytes: 0),
            BolaCell(identity: "owner-0002", objectID: "0002", authorized: true, status: 200, bodySHA256: "B2", bodyBytes: 12),
        ]
        let s = try BolaSweep.evaluate(cells)
        XCTAssertFalse(s.present)
    }

    func testDuplicateCellsRejected() {
        let cells = [
            BolaCell(identity: "a", objectID: "1", authorized: true, status: 200, bodySHA256: "x", bodyBytes: 1),
            BolaCell(identity: "a", objectID: "1", authorized: true, status: 200, bodySHA256: "x", bodyBytes: 1),
        ]
        XCTAssertThrowsError(try BolaSweep.evaluate(cells))
    }

    func testOwnershipHelper() {
        let id = BolaIdentity(label: "owner", ownedObjectIDs: ["0001", "0003"])
        XCTAssertTrue(id.owns("0001"))
        XCTAssertFalse(id.owns("0002"))
    }
}
