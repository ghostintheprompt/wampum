import XCTest
@testable import Wampum
@testable import WorkbenchCore
final class BrowserReceiptAppTests:XCTestCase {
    @MainActor func fixture(_ mode:String)async throws->(URL,WorkbenchModel,BrowserCall){
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let script=root.appendingPathComponent("server.py")
        let code = #"""
import sys,json
mode=sys.argv[1]
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': value={'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
 elif r['method']=='tools/call':
  name=r['params']['name']
  if name=='browser_click' and mode=='disconnect': sys.exit(0)
  if name=='browser_click' and mode=='action-error': value={'isError':True,'content':[{'type':'text','text':'tool reported action error'}]}
  elif name=='browser_snapshot' and mode=='refresh-error': value={'isError':True,'content':[{'type':'text','text':'snapshot permission denied'}]}
  elif name=='browser_take_screenshot': value={'isError':True,'content':[{'type':'text','text':'capture deliberately unavailable'}]}
  else: value={'content':[{'type':'text','text':'UPDATED_FIXTURE_PAGE'}]}
 else: value={}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}),flush=True)
"""#
        try Data(code.utf8).write(to:script)
        let m=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));let b=m.browser
        try await b.connection.start(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",script.path,mode],directory:root,localOnly:true)
        b.connected=true;b.snapshotFresh=true;b.tools=[try JSONDecoder().decode(MCPTool.self,from:Data(#"{"name":"browser_click","inputSchema":{"type":"object"}}"#.utf8))]
        let call=BrowserCall(name:"browser_click",arguments:.object(["target":.string("e1")]))
        b.proposed=call;b.proposedControllerID=UUID();return(root,m,call)
    }
    @MainActor func finished(_ b:BrowserModel)async throws {for _ in 0..<200 {if !b.busy{return};try await Task.sleep(nanoseconds:20_000_000)};XCTFail("Fixture did not complete")}
    @MainActor func testRefreshFailureDoesNotTurnSuccessfulActionIntoFailedAction()async throws {
        let(root,m,call)=try await fixture("refresh-error");defer{try? FileManager.default.removeItem(at:root)}
        let id=try XCTUnwrap(m.browser.proposedControllerID);m.browser.execute(call,model:m);try await finished(m.browser)
        let r=try XCTUnwrap(m.browser.receipts.last);XCTAssertEqual(r.execution,.succeeded);XCTAssertEqual(r.refresh,.failed);XCTAssertEqual(r.capture,.failed);XCTAssertFalse(m.browser.snapshotFresh)
        XCTAssertTrue(m.browser.actionOutcomes[id]?.contains("Tool succeeded")==true);XCTAssertTrue(m.browser.status.contains("Do not repeat"));XCTAssertNoThrow(try m.browser.validate(call))
        XCTAssertTrue(m.browser.snapshot.contains("observation unavailable"));await m.browser.connection.stop()
    }
    @MainActor func testCaptureFailurePreservesSuccessfulActionAndFreshDOM()async throws {
        let(root,m,call)=try await fixture("capture-error");defer{try? FileManager.default.removeItem(at:root)}
        m.browser.execute(call,model:m);try await finished(m.browser)
        let r=try XCTUnwrap(m.browser.receipts.last);XCTAssertEqual(r.execution,.succeeded);XCTAssertEqual(r.refresh,.succeeded);XCTAssertEqual(r.capture,.failed);XCTAssertTrue(m.browser.snapshotFresh)
        XCTAssertTrue(m.browser.status.contains("screenshot failed"));XCTAssertNoThrow(try m.browser.validate(call));await m.browser.connection.stop()
    }
    @MainActor func testReportedToolErrorIsNotInventedAsSuccess()async throws {
        let(root,m,call)=try await fixture("action-error");defer{try? FileManager.default.removeItem(at:root)}
        m.browser.execute(call,model:m);try await finished(m.browser);XCTAssertEqual(m.browser.receipts.last?.execution,.reportedFailure);XCTAssertEqual(m.browser.receipts.last?.refresh,.notRequested);XCTAssertThrowsError(try m.browser.validate(call));await m.browser.connection.stop()
    }
    @MainActor func testLostResponseRemainsUnknownAcrossRestartWithoutReplay()async throws {
        let(root,m,call)=try await fixture("disconnect");defer{try? FileManager.default.removeItem(at:root)}
        m.browser.execute(call,model:m);try await finished(m.browser);XCTAssertEqual(m.browser.receipts.last?.execution,.unknown)
        let restored=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertEqual(restored.browser.receipts.last?.execution,.unknown);XCTAssertThrowsError(try restored.browser.validate(call));XCTAssertFalse(restored.browser.busy);XCTAssertFalse(restored.browser.connected);await m.browser.connection.stop()
    }
    @MainActor func testPendingRecoveryAndCorruptHistoryPreservation()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let state=root.appendingPathComponent("state");let store=try BrowserReceiptStore(root:state,scope:"general")
        let call=BrowserCall(name:"browser_click",arguments:.object(["target":.string("e1")]))
        var r=BrowserReceipt(call:call);r.execution = .inFlight
        var success=BrowserReceipt(call:BrowserCall(name:"browser_type",arguments:.object([:])));success.execution = .succeeded;success.refresh = .pending;success.capture = .pending
        try store.save([r,success])
        let restored=WorkbenchModel(stateDirectory:state);XCTAssertEqual(restored.browser.receipts.first?.execution,.unknown);XCTAssertEqual(restored.browser.receipts.last?.execution,.succeeded);XCTAssertEqual(restored.browser.receipts.last?.refresh,.failed);XCTAssertEqual(restored.browser.receipts.last?.capture,.failed);XCTAssertThrowsError(try restored.browser.validate(call))
        let file=store.directory.appendingPathComponent("recent.json");try Data("broken".utf8).write(to:file)
        let corrupt=WorkbenchModel(stateDirectory:state);corrupt.browser.connected=true;corrupt.browser.execute(call);XCTAssertEqual(try String(contentsOf:file),"broken");XCTAssertTrue(corrupt.browser.status.contains("no tool call sent"))
    }
    @MainActor func testExplicitApprovalBindsReceiptAndReplaysThroughActualMonitor()async throws {
        let(root,m,_)=try await fixture("capture-error");defer{try? FileManager.default.removeItem(at:root)}
        m.browser.snapshot="PRIVATE_PAGE_CONTEXT";m.session.scope="PRIVATE_SCOPE";m.session.notes="PRIVATE_NOTES"
        m.browser.approveProposal(model:m);try await finished(m.browser)
        let receipt=try XCTUnwrap(m.browser.receipts.last), provenance=try XCTUnwrap(receipt.provenance), approval=try XCTUnwrap(provenance.approval)
        XCTAssertEqual(receipt.execution,.succeeded);XCTAssertEqual(approval.callSHA256,receipt.fingerprint);XCTAssertEqual(approval.scopeID,"general")
        XCTAssertEqual(provenance.proposalSource,"external-controller");XCTAssertNotNil(provenance.pageSHA256)
        let data=try JSONEncoder().encode([receipt]), text=String(decoding:data,as:UTF8.self)
        for secret in ["PRIVATE_PAGE_CONTEXT","PRIVATE_SCOPE","PRIVATE_NOTES"]{XCTAssertFalse(text.contains(secret))}
        let input=root.appendingPathComponent("receipts.json"),output=root.appendingPathComponent("report.json")
        try data.write(to:input)
        let monitor=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("coding_agent_monitor_lab/replay.js")
        guard FileManager.default.fileExists(atPath:monitor.path) else{await m.browser.connection.stop();throw XCTSkip("Sibling monitor checkout unavailable.")}
        guard FileManager.default.isExecutableFile(atPath:m.browser.nodePath) else{await m.browser.connection.stop();throw XCTSkip("Installed Node runtime unavailable.")}
        let process=Process();process.executableURL=URL(fileURLWithPath:m.browser.nodePath);process.arguments=[monitor.path,"--input",input.path,"--format","wampum","--expected","ui_interaction","--scenario","general","--output",output.path];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let report=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        XCTAssertEqual((report["authorizationEvidence"] as? [[String:Any]])?.count,1)
        XCTAssertEqual((report["sourceEvidence"] as? [[String:Any]])?.count,1)
        XCTAssertEqual((report["findings"] as? [[String:Any]])?.count,0)
        let artifact=URL(fileURLWithPath:"/private/tmp/wampum-provenance-fixture-report.json");try Data(contentsOf:output).write(to:artifact,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:artifact.path)
        await m.browser.connection.stop()
    }
    @MainActor func testRawExecutionDoesNotInventOperatorApproval()async throws {
        let(root,m,call)=try await fixture("capture-error");defer{try? FileManager.default.removeItem(at:root)}
        m.browser.execute(call,model:m);try await finished(m.browser)
        XCTAssertNil(m.browser.receipts.last?.provenance?.approval)
        let loaded=try BrowserReceiptStore(root:m.store.directory,scope:"general").load()
        XCTAssertNil(loaded.last?.provenance?.approval);XCTAssertEqual(loaded.last?.provenance?.callSHA256,loaded.last?.fingerprint)
        await m.browser.connection.stop()
    }

}
