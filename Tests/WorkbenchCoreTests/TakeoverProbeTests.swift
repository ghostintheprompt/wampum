import XCTest
@testable import WorkbenchCore

final class TakeoverProbeTests: XCTestCase {
    func testElbDanglingIsWeakNotTakeover() {
        let v = TakeoverProbe.classify(host: "ac-lb-test.klaviyo-dev.com",
            cnameTarget: "ac-test-public-lb-1318934321.us-east-1.elb.amazonaws.com.", targetResolves: false)
        XCTAssertEqual(v.confidence, .weak)
        XCTAssertFalse(v.reclaimable)
        XCTAssertEqual(v.service, "AWS ELB")
    }

    func testDigitalOceanDanglingIsWeak() {
        let v = TakeoverProbe.classify(host: "fulfilled-app.klaviyo-dev.com",
            cnameTarget: "fulfilled-nx4ge.ondigitalocean.app.", targetResolves: false)
        XCTAssertEqual(v.confidence, .weak)
    }

    func testGithubPagesUnclaimedIsStrong() {
        let v = TakeoverProbe.classify(host: "blog.example.com", cnameTarget: "someorg.github.io",
            targetResolves: false, body: "<h1>404</h1> There isn't a GitHub Pages site here.")
        XCTAssertEqual(v.confidence, .strong)
        XCTAssertTrue(v.reclaimable)
    }

    func testS3NoSuchBucketIsStrong() {
        let v = TakeoverProbe.classify(host: "assets.example.com", cnameTarget: "assets.example.com.s3.amazonaws.com",
            targetResolves: false, body: "<Error><Code>NoSuchBucket</Code></Error>")
        XCTAssertEqual(v.confidence, .strong)
    }

    func testReclaimableDanglingNoBodyIsModerate() {
        let v = TakeoverProbe.classify(host: "x.example.com", cnameTarget: "x.herokuapp.com", targetResolves: false)
        XCTAssertEqual(v.confidence, .moderate)
    }

    func testResolvingTargetIsNone() {
        let v = TakeoverProbe.classify(host: "live.example.com", cnameTarget: "live.github.io", targetResolves: true)
        XCTAssertEqual(v.confidence, .none)
    }
}
