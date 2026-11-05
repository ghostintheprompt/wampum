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

    func testBoilerplateResponsesDemotedToWeak() throws {
        // attacker gets 200 with the SAME body across 3 objects it doesn't own -> boilerplate -> weak.
        var cells: [BolaCell] = []
        for i in 1...3 {
            cells.append(BolaCell(identity: "owner\(i)", objectID: "\(i)", authorized: true, status: 200, bodySHA256: "OWN\(i)", bodyBytes: 50))
            cells.append(BolaCell(identity: "attacker", objectID: "\(i)", authorized: false, status: 200, bodySHA256: "DENY", bodyBytes: 20))
        }
        let s = try BolaSweep.evaluate(cells)
        XCTAssertEqual(s.crossTenant.count, 3)
        XCTAssertTrue(s.crossTenant.allSatisfy { $0.confidence == .weak }, "uniform boilerplate across objects must be weak, not a read")
        XCTAssertTrue(s.strongHits.isEmpty)
    }

    func testOwnerIdenticalIsStrongConfidence() throws {
        let cells = [
            BolaCell(identity: "owner", objectID: "7", authorized: true, status: 200, bodySHA256: "REAL", bodyBytes: 40),
            BolaCell(identity: "attacker", objectID: "7", authorized: false, status: 200, bodySHA256: "REAL", bodyBytes: 40),
        ]
        let s = try BolaSweep.evaluate(cells)
        XCTAssertEqual(s.strongHits.count, 1)
        XCTAssertEqual(s.crossTenant.first?.confidence, .strong)
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
