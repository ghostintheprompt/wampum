import XCTest
@testable import WorkbenchCore

final class SubdomainReconTests: XCTestCase {
    func testParsesJSONLAndPlainList() throws {
        let jsonl = "{\"host\":\"a.example.com\",\"source\":\"crt\"}\n{\"host\":\"B.example.com\"}\nc.example.com\n\n# junk line still a host? no\n"
        let hosts = try SubdomainImport.hosts(from: Data(jsonl.utf8))
        XCTAssertTrue(hosts.contains("a.example.com"))
        XCTAssertTrue(hosts.contains("b.example.com"))   // lowercased
        XCTAssertTrue(hosts.contains("c.example.com"))
        XCTAssertEqual(Set(hosts).count, hosts.count)     // deduped
    }

    func testRankSortsStrongFirstAndTagsRealData() {
        // mirrors the real IB/Klaviyo pass: ELB danglers weak, an unclaimed GitHub Pages strong.
        let recs = [
            TakeoverProbe.Record(host: "auto.lh360.com", cnameTarget: "prod-lighthouse-www1-1679982115.us-east-1.elb.amazonaws.com.", targetResolves: false),
            TakeoverProbe.Record(host: "blog.acme.com", cnameTarget: "acme.github.io", targetResolves: false, body: "There isn't a GitHub Pages site here."),
            TakeoverProbe.Record(host: "live.acme.com", cnameTarget: "live.github.io", targetResolves: true),
        ]
        let ranked = TakeoverProbe.rank(recs)
        XCTAssertEqual(ranked.first?.host, "blog.acme.com")          // strong at top
        XCTAssertEqual(ranked.first?.confidence, .strong)
        XCTAssertEqual(ranked.first { $0.host == "auto.lh360.com" }?.confidence, .weak)
        XCTAssertEqual(ranked.last?.confidence, .clear)               // resolving target last
    }
}
