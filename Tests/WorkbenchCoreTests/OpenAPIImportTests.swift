import XCTest
@testable import WorkbenchCore

final class OpenAPIImportTests: XCTestCase {
    private let spec = """
    {"openapi":"3.0.0","info":{"title":"t","version":"1"},"paths":{
      "/users/{id}/orders":{"get":{"operationId":"listOrders"},"post":{}},
      "/health":{"get":{"operationId":"health"}}
    }}
    """

    func testExtractsOperationsAndFlagsObjectOwnership() throws {
        let ops = try OpenAPIImport.operations(from: Data(spec.utf8))
        XCTAssertEqual(ops.count, 3)
        // Sorted by path then method.
        XCTAssertEqual(ops[0].path, "/health"); XCTAssertEqual(ops[0].method, "GET")
        XCTAssertFalse(ops[0].objectOwnershipCandidate)
        let listOrders = ops.first { $0.operationId == "listOrders" }!
        XCTAssertEqual(listOrders.method, "GET")
        XCTAssertEqual(listOrders.pathParams, ["id"])
        XCTAssertTrue(listOrders.objectOwnershipCandidate, "path with an id param is a BOLA/IDOR candidate")
        // The POST on the same path inherits the id param.
        XCTAssertTrue(ops.contains { $0.method == "POST" && $0.pathParams == ["id"] })
    }

    func testPathParameterExtraction() {
        XCTAssertEqual(OpenAPIImport.pathParameters(in: "/a/{x}/b/{y}"), ["x", "y"])
        XCTAssertEqual(OpenAPIImport.pathParameters(in: "/health"), [])
    }

    func testRejectsNonSpec() {
        XCTAssertThrowsError(try OpenAPIImport.operations(from: Data("{\"paths\":{}}".utf8)))        // no openapi field
        XCTAssertThrowsError(try OpenAPIImport.operations(from: Data("not json".utf8)))
        XCTAssertThrowsError(try OpenAPIImport.operations(from: Data("{\"openapi\":\"3.0.0\"}".utf8))) // no paths
    }
}
