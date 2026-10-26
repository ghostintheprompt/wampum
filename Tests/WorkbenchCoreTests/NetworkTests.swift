import XCTest
@testable import WorkbenchCore
final class NetworkTests:XCTestCase {
    func testLiteralLoopbackAndLookalikes(){
        for text in ["http://127.0.0.1:11434","http://localhost:1234","http://[::1]:11434"]{XCTAssertTrue(NetworkGuard.isLoopback(URL(string:text)!))}
        for text in ["https://example.test","http://localhost.example.test","http://127.0.0.1.example.test","http://user@localhost","http://192.168.1.2","file:///tmp/data"]{XCTAssertFalse(NetworkGuard.isLoopback(URL(string:text)!))}
    }
    func testDefaultPlanIsGuarded()throws{let p=try CommandPlan.make(command:"echo local");XCTAssertEqual(p.executable.path,"/usr/bin/sandbox-exec");XCTAssertTrue(p.arguments.contains(CommandPlan.loopbackProfile))}
    func testOneRunGrantDoesNotChangeDefault()throws{XCTAssertEqual(try CommandPlan.make(command:"echo allowed",externalAllowed:true).networkDecision,"EXTERNAL_ALLOWED_ONCE");XCTAssertEqual(try CommandPlan.make(command:"echo local").networkDecision,"DIRECT_SOCKETS_LOOPBACK_ONLY")}
    func testEmptyCommandRejected(){XCTAssertThrowsError(try CommandPlan.make(command:"  "))}
    func executePython(_ script:String)throws->(Int32,String){
        let command="/usr/bin/python3 -c '"+script.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let plan=try CommandPlan.make(command:command);let p=Process();p.executableURL=plan.executable;p.arguments=plan.arguments;let pipe=Pipe();p.standardOutput=pipe;p.standardError=pipe;try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();return(p.terminationStatus,String(decoding:data,as:UTF8.self))
    }
    func testRealLoopbackSocketAllowed()throws{
        let r=try executePython("import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); s.listen(1); c=socket.create_connection(s.getsockname(),1); print(\"LOCAL_CONNECTED\"); c.close(); s.close()")
        XCTAssertEqual(r.0,0,r.1);XCTAssertTrue(r.1.contains("LOCAL_CONNECTED"))
    }
    func testRealNonlocalSocketDenied()throws{
        let r=try executePython("import socket\ns=socket.socket(); s.settimeout(1)\ntry:\n s.connect((\"192.0.2.1\",443))\n raise RuntimeError(\"unexpected connection\")\nexcept PermissionError:\n print(\"NONLOCAL_DENIED\")")
        XCTAssertEqual(r.0,0,r.1);XCTAssertTrue(r.1.contains("NONLOCAL_DENIED"))
    }
    func testGuardRecordsBlockedHostWithoutQuery()async throws{
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let g=NetworkGuard(directory:dir)
        do{try await g.authorize(URL(string:"https://example.test/private?token=SECRET")!,component:"fixture",operation:"test");XCTFail("Expected block")}catch{}
        let records=try await g.recent();XCTAssertEqual(records.count,1);XCTAssertEqual(records[0].decision,"NONLOCAL_BLOCKED");XCTAssertFalse(records[0].destination.contains("SECRET"));XCTAssertFalse(records[0].destination.contains("private"))
    }
    func testGuardRecordsLocalRequest()async throws{
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let g=NetworkGuard(directory:dir);try await g.authorize(URL(string:"http://127.0.0.1:11434/api/tags")!,component:"Ollama",operation:"api/tags");let records=try await g.recent();XCTAssertEqual(records.first?.decision,"LOCAL_ALLOWED")
    }
    func testRealHTTPRedirectIsRefusedAndLogged()async throws{
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-u","-c", "import http.server\nclass H(http.server.BaseHTTPRequestHandler):\n def do_GET(self):\n  self.send_response(302); self.send_header('Location','http://example.test/private?token=SECRET'); self.end_headers()\n def log_message(self,*a): pass\ns=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.handle_request(); s.server_close()"]
        let pipe=Pipe();server.standardOutput=pipe;server.standardError=FileHandle.nullDevice;try server.run();defer{if server.isRunning{server.terminate()}}
        var bytes=Data()
        while !bytes.contains(10){guard let byte=try pipe.fileHandleForReading.read(upToCount:1),!byte.isEmpty else{throw WorkbenchError.invalid("Fixture server failed")};bytes.append(byte)}
        let port=String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let guardrail=NetworkGuard(directory:dir);let client=try OllamaClient(base:URL(string:"http://127.0.0.1:\(port)")!,guardrail:guardrail)
        do{_=try await client.models();XCTFail("Expected HTTP redirect refusal")}catch{}
        for _ in 0..<20{if try await guardrail.recent().contains(where:{$0.decision=="REDIRECT_BLOCKED"}){break};try await Task.sleep(nanoseconds:20_000_000)}
        let records=try await guardrail.recent();XCTAssertTrue(records.contains{$0.decision=="REDIRECT_BLOCKED"});XCTAssertFalse(records.contains{$0.destination.contains("SECRET")})
    }

}
