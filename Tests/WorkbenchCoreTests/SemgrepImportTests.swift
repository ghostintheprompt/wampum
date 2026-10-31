import XCTest
@testable import WorkbenchCore

final class SemgrepImportTests: XCTestCase {
    private let sample = """
    {"results":[
      {"check_id":"python.lang.security.audit.dangerous-exec","path":"app/run.py","start":{"line":42},
       "extra":{"message":"Detected exec() with user input","severity":"ERROR"}},
      {"check_id":"generic.secrets.hardcoded-token","path":"config/prod.py","start":{"line":7},
       "extra":{"message":"Hardcoded token","severity":"WARNING"}}
    ],"errors":[]}
    """

    func testParsesFindings() throws {
        let findings = try SemgrepImport.findings(from: Data(sample.utf8))
        XCTAssertEqual(findings.count, 2)
        let exec = findings.first { $0.checkID.contains("dangerous-exec") }!
        XCTAssertEqual(exec.path, "app/run.py")
        XCTAssertEqual(exec.line, 42)
        XCTAssertEqual(exec.severity, "ERROR")
        XCTAssertTrue(exec.message.contains("exec()"))
    }

    func testRejectsNonSemgrepJSON() {
        XCTAssertThrowsError(try SemgrepImport.findings(from: Data("not json".utf8)))
        XCTAssertThrowsError(try SemgrepImport.findings(from: Data("{\"nope\":1}".utf8)))
    }

    func testToleratesMissingOptionalFields() throws {
        let f = try SemgrepImport.findings(from: Data("{\"results\":[{\"check_id\":\"x\",\"path\":\"a.py\"}]}".utf8))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].line, 0)
        XCTAssertEqual(f[0].severity, "INFO")
    }
}
