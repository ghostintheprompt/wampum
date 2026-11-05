import XCTest
@testable import WorkbenchCore

final class ReconLeadScoringTests: XCTestCase {
    func testFfufScoreDemotesCatchAllAndKeepsRealLeads() {
        var rs: [FfufResult] = []
        for i in 0..<18 { rs.append(FfufResult(url: "http://t/\(i)", status: 200, length: 1500, input: "\(i)")) } // catch-all
        rs.append(FfufResult(url: "http://t/admin", status: 403, length: 90, input: "admin"))        // gated, exists
        rs.append(FfufResult(url: "http://t/config.json", status: 200, length: 640, input: "config.json")) // unique 2xx
        let leads = FfufImport.score(rs)
        XCTAssertEqual(leads.count, 20)
        XCTAssertTrue(leads.filter { $0.result.length == 1500 }.allSatisfy { $0.confidence == .weak })
        XCTAssertEqual(leads.first { $0.result.input == "admin" }?.confidence, .strong)
        XCTAssertEqual(leads.first { $0.result.input == "config.json" }?.confidence, .strong)
    }

    func testFfufScoreEmpty() {
        XCTAssertTrue(FfufImport.score([]).isEmpty)
    }
}
