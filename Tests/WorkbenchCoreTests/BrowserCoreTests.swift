import XCTest
@testable import WorkbenchCore

final class BrowserCoreTests:XCTestCase {
    func testExecutionHookBindsApprovalAndRejectsReplayAcrossRestore()throws {
        let call=BrowserCall(name:"browser_click",arguments:.object(["ref":.string("e1")]))
        let changed=BrowserCall(name:"browser_click",arguments:.object(["ref":.string("e2")]))
        let approval=BrowserApproval(call:call,scopeID:"case-a")
        var gate=BrowserRetryGate()
        XCTAssertThrowsError(try gate.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:nil))
        XCTAssertThrowsError(try gate.authorizeExecution(changed,scopeID:"case-a",requiresApproval:true,approval:approval))
        XCTAssertThrowsError(try gate.authorizeExecution(call,scopeID:"case-b",requiresApproval:true,approval:approval))
        try gate.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:approval)
        var restored=try JSONDecoder().decode(BrowserRetryGate.self,from:JSONEncoder().encode(gate))
        restored.resetRejections()
        XCTAssertThrowsError(try restored.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:approval))
        XCTAssertNoThrow(try restored.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:BrowserApproval(call:call,scopeID:"case-a")))
    }
    func testExecutionHookRejectsChangedObservedContext()throws {
        let call=BrowserCall(name:"browser_click",arguments:.object(["ref":.string("e1")]))
        let approval=BrowserApproval(call:call,scopeID:"case-a",contextSHA256:"observed-a")
        var gate=BrowserRetryGate()
        XCTAssertThrowsError(try gate.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:approval,contextSHA256:"observed-b"))
        XCTAssertNoThrow(try gate.authorizeExecution(call,scopeID:"case-a",requiresApproval:true,approval:approval,contextSHA256:"observed-a"))
    }
    func testExecutionHookRetainsDirectOperatorReadAndOldGateCompatibility()throws {
        var gate=try JSONDecoder().decode(BrowserRetryGate.self,from:Data("{\"rejections\":{}}".utf8))
        XCTAssertNoThrow(try gate.authorizeExecution(BrowserCall(name:"browser_snapshot",arguments:.object([:])),scopeID:"general",requiresApproval:false,approval:nil))
    }
    func testCanonicalRejectedRequestsAndPersistence()throws {
        let a=BrowserCall(name:"browser_click",arguments:.object(["target":.string("a"),"button":.string("left")]))
        let b=BrowserCall(name:"browser_click",arguments:.object(["button":.string("left"),"target":.string("a")]))
        var gate=BrowserRetryGate();gate.reject(a,reason:"operator denied")
        let restored=try JSONDecoder().decode(BrowserRetryGate.self,from:JSONEncoder().encode(gate))
        XCTAssertEqual(a.fingerprint,b.fingerprint);XCTAssertThrowsError(try restored.check(b))
        XCTAssertThrowsError(try restored.check(BrowserCall(name:"browser_click",arguments:.object(["target":.string("different")]))))
        XCTAssertNoThrow(try restored.check(BrowserCall(name:"browser_snapshot",arguments:.object([:]))))
    }
    func testImageRESTPayloadToLoopbackFixture() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let script = #"""
import http.server,json
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  ok=body['messages'][-1].get('images')==['RklYVFVSRQ=='] and body['messages'][-1]['role']=='user' and body.get('think')==False
  self.send_response(200 if ok else 400);self.end_headers();self.wfile.write(json.dumps({'message':{'content':'PAYLOAD_OK' if ok else 'BAD_PAYLOAD'}}).encode())
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H);s.timeout=5;print(s.server_port,flush=True);s.handle_request();s.server_close()
"""#
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=["-u","-c",script]
        let pipe=Pipe();p.standardOutput=pipe;p.standardError=FileHandle.nullDevice;try p.run();defer{if p.isRunning{p.terminate()}}
        var first=Data();while !first.contains(10){guard let byte=try pipe.fileHandleForReading.read(upToCount:1),!byte.isEmpty else{throw WorkbenchError.invalid("Image payload fixture failed")};first.append(byte)}
        let port=String(decoding:first,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let client=try OllamaClient(base:URL(string:"http://127.0.0.1:"+port)!,guardrail:NetworkGuard(directory:root))
        let packet=try ContextPacket.build(system:"Fixture",history:[ChatMessage(role:"user",content:"Inspect")],context:8192,extraTokens:2048)
        let reply=try await client.chat(model:"fixture-vision",packet:packet,context:8192,thinking:false,supportsThinking:true,images:["RklYVFVSRQ=="])
        XCTAssertEqual(reply.message.content,"PAYLOAD_OK")
    }
    func testToolSchemasAndReplyDecode()throws {
        let tool=try JSONDecoder().decode(MCPTool.self,from:Data(#"{"name":"browser_click","description":"Click","inputSchema":{"type":"object","properties":{"target":{"type":"string"}}}}"#.utf8))
        XCTAssertEqual(tool.ollama["function"]?["name"]?.string,"browser_click")
        let reply=try JSONDecoder().decode(BrowserPlanReply.self,from:Data(#"{"message":{"content":"","tool_calls":[{"function":{"name":"browser_click","arguments":{"target":"e2"}}}]}}"#.utf8))
        XCTAssertEqual(reply.message.tool_calls?.first?.function.arguments["target"]?.string,"e2")
    }
    func testLocalBrowserSocketPolicy() async throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("wmp-policy-"+String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:root)}
        let script="""
        import socket,os
        path=\(String(reflecting:root.appendingPathComponent("fixture.sock").path))
        s=socket.socket(socket.AF_UNIX);s.bind(path);s.listen(1)
        c=socket.socket(socket.AF_UNIX);c.connect(path);print('LOCAL_UNIX_OK',flush=True)
        try:
         socket.create_connection(('192.0.2.1',80),timeout=0.5)
         print('UNEXPECTED_EXTERNAL_CONNECTION',flush=True)
        except PermissionError: print('NONLOCAL_DENIED',flush=True)
        c.close();s.close();os.unlink(path)
        """
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec");p.arguments=["-p",MCPConnection.localBrowserProfile(socketDirectory:root),"/usr/bin/python3","-u","-c",script]
        let pipe=Pipe();p.standardOutput=pipe;p.standardError=pipe;try p.run();defer{if p.isRunning{p.terminate()}}
        for _ in 0..<100 {if !p.isRunning{break};try await Task.sleep(nanoseconds:25_000_000)}
        guard !p.isRunning else{throw WorkbenchError.invalid("Socket policy fixture timed out")}
        let output=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        XCTAssertEqual(p.terminationStatus,0,output);XCTAssertTrue(output.contains("LOCAL_UNIX_OK"),output);XCTAssertTrue(output.contains("NONLOCAL_DENIED"),output)
    }
    func testToolSchemaReserveProtectsSmallContext()throws {
        XCTAssertThrowsError(try ContextPacket.build(system:"short",history:[ChatMessage(role:"user",content:"short")],context:4096,extraTokens:4000))
        let packet=try ContextPacket.build(system:"short",history:[ChatMessage(role:"user",content:"short")],context:8192,extraTokens:2000)
        XCTAssertGreaterThan(packet.estimatedTokens,2000)
    }
    func testRealStdioTransportTimeoutAndDisconnect()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let script=root.appendingPathComponent("fixture.py")
        try Data(#"""
import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='hang': continue
 if r['method']=='large': value={'payload':'X'*1000000}
 elif r['method']=='initialize': value={'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
 elif r['method']=='tools/list':
  print(json.dumps({'jsonrpc':'2.0','id':'server-ping','method':'ping'}),flush=True)
  pong=json.loads(sys.stdin.readline());assert pong.get('result')=={},pong
  value={'tools':[{'name':'browser_snapshot','inputSchema':{'type':'object'}}]}
 else: value={'content':[{'type':'text','text':'fixture result'}]}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}),flush=True)
"""#.utf8).write(to:script)
        let connection=MCPConnection()
        try await connection.start(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",script.path],directory:root,localOnly:true)
        let tools=try await connection.tools();XCTAssertEqual(tools.first?.name,"browser_snapshot")
        for _ in 0..<3 {let large=try await connection.request("large");XCTAssertEqual(large["payload"]?.string?.count,1_000_000)}
        let result=try await connection.call(BrowserCall(name:"browser_snapshot",arguments:.object([:])))
        XCTAssertEqual(result["content"]?.array?.first?["text"]?.string,"fixture result")
        do{_=try await connection.request("hang",timeout:0.05);XCTFail("Expected timeout")}catch{XCTAssertTrue(error.localizedDescription.contains("timed out"))}
        await connection.stop()
        do{_=try await connection.tools();XCTFail("Expected disconnected error")}catch{}
    }
}
