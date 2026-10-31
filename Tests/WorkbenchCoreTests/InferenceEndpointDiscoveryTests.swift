import XCTest
@testable import WorkbenchCore

final class InferenceEndpointDiscoveryTests: XCTestCase {
    func testCandidatePathsCoverCommonAPIs() {
        let p = InferenceEndpointDiscovery.candidatePaths()
        XCTAssertTrue(p.contains("/api/tags"))
        XCTAssertTrue(p.contains("/v1/models"))
        XCTAssertFalse(p.isEmpty)
    }
    func testClassifyDetectsKnownEndpoints() {
        XCTAssertEqual(InferenceEndpointDiscovery.classify(path: "/api/tags", status: 200, body: "{\"models\":[]}"), "ollama")
        XCTAssertEqual(InferenceEndpointDiscovery.classify(path: "/v1/models", status: 200, body: "{\"object\":\"list\",\"data\":[]}"), "openai-compatible")
        XCTAssertEqual(InferenceEndpointDiscovery.classify(path: "/.well-known/ai-plugin.json", status: 200, body: "{\"schema_version\":\"v1\"}"), "ai-plugin-manifest")
    }
    func testClassifyRejectsNonEndpoints() {
        XCTAssertNil(InferenceEndpointDiscovery.classify(path: "/api/tags", status: 404, body: "not found"))
        XCTAssertNil(InferenceEndpointDiscovery.classify(path: "/v1/models", status: 200, body: "<html>welcome</html>"))
        XCTAssertNil(InferenceEndpointDiscovery.classify(path: "/health", status: 200, body: "ok"))
    }
}
