import XCTest
@testable import WorkbenchCore
final class ProxyTests:XCTestCase {
    private func waitForFixture(_ process:Process) async throws {
        for _ in 0..<200 {
            if !process.isRunning {return}
            try await Task.sleep(nanoseconds:25_000_000)
        }
        if process.isRunning {process.terminate()}
        throw WorkbenchError.invalid("Proxy fixture did not exit within five seconds.")
    }
    func testProxySchemesAndNoFallback()throws{
        for value in ["http://127.0.0.1:8080","https://proxy.example:443","socks5://127.0.0.1:1080"]{let p=try ProxySpec(value);XCTAssertFalse(p.configuration().allowFailover)}
    }
    func testBadProxyRejected(){for value in ["","ftp://example.test:21","http://user:password@example.test:80","http://example.test:0","http://example.test:8080/path","http://example.test:8080?q=1"]{XCTAssertThrowsError(try ProxySpec(value),value)}}
    func testHTTPSOnlyReview(){XCTAssertThrowsError(try ProxyProbeReview(urlString:"http://example.test",proxyString:"http://127.0.0.1:8080"));XCTAssertThrowsError(try ProxyProbeReview(urlString:"https://user:pass@example.test",proxyString:"http://127.0.0.1:8080"));XCTAssertThrowsError(try ProxyProbeReview(urlString:"https://example.test/#fragment",proxyString:"http://127.0.0.1:8080"))}
    func testRealHTTPConnectUsesProxyAndConsumesApproval()async throws{
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-u","-c","import http.server\nclass H(http.server.BaseHTTPRequestHandler):\n def do_CONNECT(self):\n  print(self.requestline,flush=True); self.send_response(502); self.end_headers()\n def log_message(self,*a): pass\ns=http.server.HTTPServer(('127.0.0.1',0),H);s.timeout=5;print(s.server_port,flush=True);s.handle_request();s.server_close()"]
        let pipe=Pipe();server.standardOutput=pipe;server.standardError=FileHandle.nullDevice;try server.run();defer{if server.isRunning{server.terminate()}}
        var first=Data();while !first.contains(10){guard let b=try pipe.fileHandleForReading.read(upToCount:1),!b.isEmpty else{throw WorkbenchError.invalid("Proxy fixture failed")};first.append(b)}
        let port=String(decoding:first,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let guardrail=NetworkGuard(directory:directory);let client=ProxyProbeClient(guardrail:guardrail);let review=try ProxyProbeReview(urlString:"https://fixture.invalid/inspect?token=PRIVATE",proxyString:"http://127.0.0.1:\(port)")
        do{_=try await client.performApproved(review);XCTFail("Rejecting proxy must fail")}catch{}
        try await waitForFixture(server);let request=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);XCTAssertTrue(request.contains("CONNECT fixture.invalid:443"),request);XCTAssertFalse(request.contains("PRIVATE"))
        do{_=try await client.performApproved(review);XCTFail("Approval reused")}catch{XCTAssertTrue(error.localizedDescription.contains("already been used"))}
        let records=try await guardrail.recent();XCTAssertTrue(records.contains{$0.decision=="PROXY_REQUEST_FAILED"});XCTAssertFalse(records.contains{$0.destination.contains("PRIVATE")})
    }
    func testRealSOCKSHandshakeUsesDestinationName()async throws{
        let script = #"""
import socket
s=socket.socket();s.bind(('127.0.0.1',0));s.listen(1);s.settimeout(5);print(s.getsockname()[1],flush=True)
c,_=s.accept();c.settimeout(5)
def exact(n):
 b=b''
 while len(b)<n:
  part=c.recv(n-len(b))
  if not part: raise RuntimeError('short handshake')
  b+=part
 return b
v,n=exact(2);exact(n);c.sendall(bytes([5,0]));v,cmd,rsv,kind=exact(4)
if kind==3: host=exact(exact(1)[0]).decode()
elif kind==1: host=socket.inet_ntop(socket.AF_INET,exact(4))
else: host=socket.inet_ntop(socket.AF_INET6,exact(16))
port=int.from_bytes(exact(2),'big');print('SOCKS '+host+':'+str(port),flush=True)
c.sendall(bytes([5,4,0,1,0,0,0,0,0,0]));c.close();s.close()
"""#
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=["-u","-c",script];let pipe=Pipe();p.standardOutput=pipe;p.standardError=FileHandle.nullDevice;try p.run();defer{if p.isRunning{p.terminate()}}
        var first=Data();while !first.contains(10){guard let b=try pipe.fileHandleForReading.read(upToCount:1),!b.isEmpty else{throw WorkbenchError.invalid("SOCKS fixture failed")};first.append(b)}
        let port=String(decoding:first,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let client=ProxyProbeClient(guardrail:NetworkGuard());let review=try ProxyProbeReview(urlString:"https://fixture.invalid/",proxyString:"socks5://127.0.0.1:\(port)")
        do{_=try await client.performApproved(review);XCTFail("Rejecting SOCKS proxy must fail")}catch{}
        try await waitForFixture(p);let output=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);XCTAssertTrue(output.contains("SOCKS fixture.invalid:443"),output)
    }

}
