import XCTest
import Darwin
import AppKit
@testable import Wampum
@testable import WorkbenchCore

final class BrowserAppTests:XCTestCase {
    @MainActor func fixture()throws->(URL,WorkbenchModel) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return(root,WorkbenchModel(stateDirectory:root.appendingPathComponent("state")))
    }
    @MainActor func testControllerProposalWithoutApprovalNeverReachesTransport()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let browser=m.browser
        let call=BrowserCall(name:"browser_click",arguments:.object(["ref":.string("e1")]))
        browser.tools=[try JSONDecoder().decode(MCPTool.self,from:Data(#"{"name":"browser_click","inputSchema":{"type":"object"}}"#.utf8))]
        browser.connected=true;browser.proposed=call;browser.proposedControllerID=UUID()
        browser.execute(call,model:m)
        XCTAssertFalse(browser.busy)
        XCTAssertEqual(browser.receipts.last?.execution,.notSent)
        XCTAssertTrue(browser.receipts.last?.detail.contains("requires approval") == true)
        XCTAssertEqual(browser.status,"Request blocked; no tool call sent.")
    }
    @MainActor func testImageCopyVisionGateAndOCR()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let image=NSImage(size:NSSize(width:700,height:160));image.lockFocus();NSColor.white.setFill();NSRect(x:0,y:0,width:700,height:160).fill()
        ("WAMPUM EVIDENCE 742" as NSString).draw(at:NSPoint(x:25,y:60),withAttributes:[.font:NSFont.systemFont(ofSize:36),.foregroundColor:NSColor.black]);image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))!
        let file=root.appendingPathComponent("fixture.png");try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:file)
        m.attachImages([file]);XCTAssertEqual(m.session.images?.count,1)
        let path=try XCTUnwrap(m.session.images?.first);XCTAssertNotEqual(path,file.path)
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data(#"{"name":"fixture-qwen"}"#.utf8))];m.session.model="fixture-qwen";m.session.prompt="Read this image";m.capabilities=["completion","tools"];m.send()
        XCTAssertFalse(m.showRequestReview);XCTAssertTrue(m.error?.contains("vision") == true)
        m.error=nil;m.extractImageText();XCTAssertTrue(m.session.prompt.contains("WAMPUM"));XCTAssertEqual(m.session.images,[]);XCTAssertNil(m.error)
        XCTAssertThrowsError(try ImageAttachments.data(file.path,directory:m.imageDirectory))
        // A fixture-only vision capability verifies review wiring, not installed-model vision.
        m.attachImages([file]);m.capabilities=["vision"];m.send();XCTAssertTrue(m.showRequestReview);XCTAssertEqual(m.pendingImages.count,1)
        let frozen=m.pendingImages;m.session.images=[];XCTAssertEqual(m.pendingImages,frozen);m.cancelRequestReview();XCTAssertTrue(m.pendingImages.isEmpty)
        print("OCR fixture: "+m.session.prompt)
    }
    @MainActor func testBrowserPolicyAndDeniedProposalBlockRepeats()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let b=m.browser
        b.tools=[try JSONDecoder().decode(MCPTool.self,from:Data(#"{"name":"browser_navigate","inputSchema":{"type":"object"}}"#.utf8))]
        XCTAssertThrowsError(try b.validate(BrowserCall(name:"browser_navigate",arguments:.object(["url":.string("https://example.test")]))))
        XCTAssertThrowsError(try b.validate(BrowserCall(name:"browser_run_code_unsafe",arguments:.object([:]))))
        let call=BrowserCall(name:"browser_navigate",arguments:.object(["url":.string("http://127.0.0.1:8000")]))
        XCTAssertNoThrow(try b.validate(call));b.proposed=call;b.denyProposal(model:m);XCTAssertThrowsError(try b.validate(call));XCTAssertTrue(b.events.contains{$0.contains("REJECTED")})
    }
    @MainActor func testLiveBrowserTransportDescendantCleanup() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_BROWSER_LIVE"] == "1" else {
            throw XCTSkip("Opt-in owned isolated Chrome cleanup test; no model call.")
        }
        let (root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let browser=m.browser;browser.livePreview=false;browser.requestConnect(scenario:nil)
        for _ in 0..<800 {if !browser.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard browser.connected else {throw WorkbenchError.invalid(browser.diagnostics)}
        let connection=browser.connection
        let result=try await connection.request("wampum/self-check")
        let url=try XCTUnwrap(result["url"]?.string)
        _ = try await connection.call(BrowserCall(name:"browser_navigate",arguments:.object(["url":.string(url)])))
        let identifier=await connection.ownedProcessIdentifier()
        let leader=try XCTUnwrap(identifier)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-axo","pid=,ppid="]
        let pipe=Pipe();process.standardOutput=pipe;try process.run()
        let table=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        let rows=table.split(separator:"\n").compactMap {line -> (Int32,Int32)? in
            let fields=line.split(whereSeparator:{$0.isWhitespace})
            guard fields.count==2,let pid=Int32(fields[0]),let parent=Int32(fields[1]) else{return nil}
            return(pid,parent)
        }
        var owned:Set<Int32>=[leader]
        while true {let previous=owned;for(pid,parent)in rows where owned.contains(parent){owned.insert(pid)};if previous==owned{break}}
        XCTAssertGreaterThan(owned.count,1,"Expected actual Chrome descendants")
        // Only exact descendants observed under the test-owned transport are cleanup candidates.
        defer{for pid in owned{_ = Darwin.kill(pid,SIGKILL)}}
        let stopped=await connection.stop();XCTAssertTrue(stopped)
        for _ in 0..<100 {if owned.allSatisfy({Darwin.kill($0,0) == -1}){break};try await Task.sleep(nanoseconds:20_000_000)}
        for pid in owned {XCTAssertEqual(Darwin.kill(pid,0),-1,"Owned browser descendant survived: \(pid)")}
        print("LIVE MCP CLEANUP: \(owned.count) observed transport/browser processes exited; no model call")
    }
    @MainActor func testLivePlaywrightPageCaptureAndQwenClick()async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_BROWSER_LIVE"] == "1" else{throw XCTSkip("Opt-in isolated Chrome / local Qwen fixture test.")}
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-u","-c",#"""
import http.server
PAGE=b'''<!doctype html><html><head><title>Wampum browser fixture</title></head><body style="background:#16171b;color:#fafafa;font:24px sans-serif;padding:45px"><h1>Local evidence bench</h1><p id="result">Evidence pending</p><button onclick="document.getElementById('result').textContent='Evidence recorded 742'">Record evidence</button><script>console.error('FIXTURE_CONSOLE_742')</script></body></html>'''
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(PAGE)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
"""#]
        let pipe=Pipe();server.standardOutput=pipe;server.standardError=FileHandle.nullDevice;try server.run();defer{server.terminate()}
        var line=Data();while !line.contains(10){line.append(try XCTUnwrap(pipe.fileHandleForReading.read(upToCount:1)))}
        let port=String(decoding:line,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let b=m.browser;b.livePreview=false;b.requestConnect(scenario:nil)
        for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard b.connected else{throw WorkbenchError.invalid(b.diagnostics)}
        b.address="http://127.0.0.1:"+port;b.navigate()
        for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard b.snapshot.contains("Record evidence"),b.screenshot != nil else{b.disconnect();throw WorkbenchError.invalid("Navigation/capture failed: "+b.diagnostics+"\n"+b.snapshot)}
        let image=try XCTUnwrap(b.screenshot);try image.write(to:URL(fileURLWithPath:"/private/tmp/wampum-playwright-fixture.jpg"))
        m.models=try await m.client.models();m.session.model="lukey03/Qwen3.5-9B-abliterated:latest";m.capabilities=try await m.client.show(m.session.model).capabilities ?? []
        b.goal="Click the button named Record evidence exactly once. Do not navigate."
        b.preparePlan(model:m);guard b.showPlanReview else{b.disconnect();throw WorkbenchError.invalid(b.diagnostics)}
        b.sendPlan(model:m)
        for _ in 0..<2400 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard let call=b.proposed else{b.disconnect();throw WorkbenchError.invalid("No proposed call: "+b.diagnostics+" "+b.explanation)}
        guard call.name=="browser_click" else{b.disconnect();throw WorkbenchError.invalid("Expected a click, got "+call.name+" "+call.arguments.pretty)};print("LIVE QWEN PROPOSAL "+call.name+" "+call.arguments.canonical)
        b.approveProposal(model:m)
        for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertEqual(b.receipts.last?.provenance?.proposalSource,"local-qwen");XCTAssertNotNil(b.receipts.last?.provenance?.reviewedRequestSHA256);XCTAssertNotNil(b.receipts.last?.provenance?.approval)
        guard b.snapshot.contains("Evidence recorded 742") else{b.disconnect();throw WorkbenchError.invalid("Click did not change the page: "+b.diagnostics+"\n"+b.snapshot)}
        b.inspectConsole();for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertTrue(b.diagnostics.contains("FIXTURE_CONSOLE_742"),b.diagnostics)
        print("LIVE BROWSER snapshot/capture/model-click/console verified")
        b.disconnect();await b.connection.stop()
    }
}
