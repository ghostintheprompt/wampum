import XCTest
@testable import WorkbenchCore

final class ReconControlTests: XCTestCase {
    private let fake = URL(fileURLWithPath: "/bin/echo")
    private let scope = AuthorizedScope(["*.target.test", "10.0.0.5"])

    func testNmapScopeGatedPlan() throws {
        let p = try ReconControl.plan(tool: .nmap, executable: fake, target: "host.target.test", extraArgs: ["-sV", "-Pn"], scope: scope)
        XCTAssertEqual(p.arguments, ["-sV", "-Pn", "host.target.test"])
        XCTAssertEqual(p.receipt.tool, "nmap")
        XCTAssertEqual(p.receipt.targets, ["host.target.test"])
    }

    func testNmapOutOfScopeFailsClosed() {
        XCTAssertThrowsError(try ReconControl.plan(tool: .nmap, executable: fake, target: "evil.example", extraArgs: [], scope: scope))
        XCTAssertThrowsError(try ReconControl.plan(tool: .nmap, executable: fake, target: "host.target.test", extraArgs: [], scope: AuthorizedScope([])))
    }

    func testFfufRequiresFuzzAndInScopeURL() throws {
        let p = try ReconControl.plan(tool: .ffuf, executable: fake, target: "https://app.target.test/FUZZ", extraArgs: ["-w", "list.txt"], scope: scope)
        XCTAssertEqual(p.arguments, ["-u", "https://app.target.test/FUZZ", "-w", "list.txt"])
        XCTAssertEqual(p.receipt.targets, ["app.target.test"])
        XCTAssertThrowsError(try ReconControl.plan(tool: .ffuf, executable: fake, target: "https://app.target.test/admin", extraArgs: [], scope: scope)) // no FUZZ
        XCTAssertThrowsError(try ReconControl.plan(tool: .ffuf, executable: fake, target: "https://evil.example/FUZZ", extraArgs: [], scope: scope)) // out of scope
    }

    func testFfufImportParsesResults() throws {
        let json = """
        {"results":[
          {"url":"https://app.target.test/admin","status":200,"length":1234,"input":{"FUZZ":"admin"}},
          {"url":"https://app.target.test/backup","status":403,"length":0,"input":{"FUZZ":"backup"}}
        ]}
        """
        let results = try FfufImport.results(from: Data(json.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].input, "admin")
        XCTAssertEqual(results[0].status, 200)
        XCTAssertThrowsError(try FfufImport.results(from: Data("{}".utf8)))
    }

    func testNmapImportParsesXML() throws {
        let xml = """
        <?xml version="1.0"?>
        <nmaprun scanner="nmap">
          <host>
            <address addr="10.0.0.5" addrtype="ipv4"/>
            <hostnames><hostname name="host.target.test" type="PTR"/></hostnames>
            <ports>
              <port protocol="tcp" portid="22"><state state="open"/><service name="ssh" product="OpenSSH"/></port>
              <port protocol="tcp" portid="80"><state state="open"/><service name="http"/></port>
            </ports>
          </host>
        </nmaprun>
        """
        let r = try NmapImport.results(from: Data(xml.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].host, "host.target.test")
        XCTAssertEqual(r[0].address, "10.0.0.5")
        XCTAssertEqual(r[0].port, 22)
        XCTAssertEqual(r[0].proto, "tcp")
        XCTAssertEqual(r[0].state, "open")
        XCTAssertEqual(r[0].service, "ssh")
        XCTAssertEqual(r[0].product, "OpenSSH")
        XCTAssertEqual(r[1].port, 80)
        XCTAssertEqual(r[1].service, "http")
    }

    func testNmapImportParsesGreppable() throws {
        let grep = "Host: 10.0.0.5 (host.target.test)\tPorts: 22/open/tcp//ssh//OpenSSH/, 443/open/tcp//https///\tIgnored State: closed (998)\n"
        let r = try NmapImport.results(from: Data(grep.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].host, "host.target.test")
        XCTAssertEqual(r[0].port, 22)
        XCTAssertEqual(r[0].state, "open")
        XCTAssertEqual(r[0].service, "ssh")
        XCTAssertEqual(r[0].product, "OpenSSH")
        XCTAssertEqual(r[1].port, 443)
        XCTAssertEqual(r[1].service, "https")
    }

    func testNmapImportParsesOSAndScriptOutput() throws {
        // nmap emits <os> after <ports>; OS must attach to the host's ports, and port scripts captured.
        let xml = """
        <?xml version="1.0"?>
        <nmaprun scanner="nmap">
          <host>
            <address addr="10.0.0.5" addrtype="ipv4"/>
            <ports>
              <port protocol="tcp" portid="80"><state state="open"/><service name="http"/>
                <script id="http-title" output="Example Domain"/></port>
            </ports>
            <os><osmatch name="Linux 5.4" accuracy="97"/></os>
          </host>
        </nmaprun>
        """
        let r = try NmapImport.results(from: Data(xml.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].port, 80)
        XCTAssertEqual(r[0].osGuess, "Linux 5.4 (97%)")
        XCTAssertTrue(r[0].scriptOutput.contains("http-title: Example Domain"))
    }

    func testNmapImportRejectsNonNmapInput() {
        // Well-formed XML, but not nmap output: no <host> element.
        XCTAssertThrowsError(try NmapImport.results(from: Data("<other><thing/></other>".utf8)))
        // Greppable-shaped text with no Host: lines.
        XCTAssertThrowsError(try NmapImport.results(from: Data("nothing here\njust text\n".utf8)))
    }
}
