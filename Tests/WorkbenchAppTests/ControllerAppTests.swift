import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ControllerAppTests:XCTestCase {
    @MainActor func fixture()throws->(URL,WorkbenchModel) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let m=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));m.session.project=root.path;m.session.scope="Fixture scope";m.session.notes="PRIVATE CLIENT";m.privacy.aliasRules="PRIVATE CLIENT => CLIENT_A";m.session.messages=[ChatMessage(role:"user",content:"HISTORY_NOT_APPROVED")]
        m.controller.prepare(model:m);m.controller.enable(model:m);return(root,m)
    }
    @MainActor func call(_ tool:String,_ m:WorkbenchModel,_ args:JSONValue = .object([:]),client:String="A")throws->JSONValue {
        let c=m.controller;let request=ControllerRequest(clientID:client,clientName:"Fixture Controller",token:try c.mailbox.access().token,tool:tool,arguments:args)
        try c.mailbox.enqueue(request);c.poll(model:m);return try XCTUnwrap(c.mailbox.response(request.id))
    }
    @MainActor func browser(_ m:WorkbenchModel)throws {
        m.browser.connected=true;m.browser.snapshotFresh=true;m.browser.tools=[try JSONDecoder().decode(MCPTool.self,from:Data(#"{"name":"browser_click","inputSchema":{"type":"object"}}"#.utf8))]
    }
    @MainActor func testFrozenHandoffNoAutomaticHistoryOrCompetingController()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.session.notes="NEW_NOT_REVIEWED";let result=try call("wampum_context",m)
        XCTAssertTrue(result["context"]?.string?.contains("CLIENT_A")==true);XCTAssertFalse(result.pretty.contains("PRIVATE CLIENT"));XCTAssertFalse(result.pretty.contains("HISTORY_NOT_APPROVED"));XCTAssertFalse(result.pretty.contains("NEW_NOT_REVIEWED"))
        XCTAssertNotNil(try call("wampum_context",m,client:"B")["error"])
        m.controller.revoke(model:m,stopBrowser:false);XCTAssertFalse(m.controller.enabled);XCTAssertFalse(FileManager.default.fileExists(atPath:m.controller.mailbox.accessURL.path))
    }
    @MainActor func testProposalDoesNotExecuteAndDeniedToolCannotBeRephrased()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)};try browser(m)
        let args:JSONValue = .object(["tool":.string("browser_click"),"arguments":.object(["target":.string("e1")]),"reason":.string("fixture click")])
        let result=try call("wampum_propose_browser_action",m,args);XCTAssertNotNil(result["ticket"]);XCTAssertNotNil(m.browser.proposed);XCTAssertFalse(m.browser.busy);XCTAssertFalse(m.browser.events.contains{$0.contains("RUN")})
        m.browser.denyProposal(model:m)
        let status=try call("wampum_status",m);XCTAssertTrue(status.pretty.contains("operator denied"))
        let changed:JSONValue = .object(["tool":.string("browser_click"),"arguments":.object(["target":.string("e99")]),"reason":.string("renamed target")])
        XCTAssertNotNil(try call("wampum_propose_browser_action",m,changed)["error"]);XCTAssertNil(m.browser.proposed)
    }
    @MainActor func testObservationRequiresExactReviewAndDenialSharesNothing()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)};try browser(m);m.browser.snapshot="PRIVATE CLIENT / PAGE_NOT_APPROVED"
        let result=try call("wampum_request_observation",m);XCTAssertFalse(result.pretty.contains("PAGE_NOT_APPROVED"))
        let ticket=try XCTUnwrap(result["ticket"]?.string);let args:JSONValue = .object(["ticket":.string(ticket)])
        XCTAssertNil(try call("wampum_read_observation",m,args)["snapshot"]);XCTAssertTrue(m.controller.observationText.contains("CLIENT_A"))
        m.controller.observationText="EXACT_REVIEWED_TEXT";m.controller.shareObservation()
        XCTAssertEqual(try call("wampum_read_observation",m,args)["snapshot"]?.string,"EXACT_REVIEWED_TEXT")
        let next=try call("wampum_request_observation",m);m.controller.denyObservation()
        let denied=try call("wampum_read_observation",m,.object(["ticket":next["ticket"]!]));XCTAssertNil(denied["snapshot"])
    }
    @MainActor func testCheckpointRequiresReviewAndScenarioChangeRevokes()throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try call("wampum_submit_checkpoint",m,.object(["text":.string("Unverified controller finding")]))
        XCTAssertEqual(m.session.notes,"PRIVATE CLIENT");m.controller.saveCheckpoint(model:m);XCTAssertTrue(m.session.notes.contains("not independently verified"));XCTAssertTrue(m.session.notes.contains("Unverified controller finding"))
        m.session.project=root.appendingPathComponent("changed").path;m.controller.poll(model:m);XCTAssertFalse(m.controller.enabled)
    }
    @MainActor func liveCall(_ tool:String,_ arguments:JSONValue = .object([:]),model:WorkbenchModel,connection:MCPConnection)async throws->JSONValue {
        let task=Task{try await connection.call(BrowserCall(name:tool,arguments:arguments))}
        for _ in 0..<200 {
            if !(try model.controller.mailbox.requests()).isEmpty {model.controller.poll(model:model);break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        let reply=try await task.value
        let text=try XCTUnwrap(reply["content"]?.array?.first?["text"]?.string)
        return try JSONDecoder().decode(JSONValue.self,from:Data(text.utf8))
    }
    @MainActor func testLiveControllerThroughRealBrowserReviewAndObservation()async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_CONTROLLER_LIVE"]=="1" else{throw XCTSkip("Opt-in local controller/Chrome integration fixture.")}
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let b=m.browser;b.livePreview=false;b.requestConnect(scenario:nil)
        for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard b.connected else{throw WorkbenchError.invalid(b.diagnostics)}
        b.loadSelfCheck();for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        guard b.snapshot.contains("Record evidence") else{b.disconnect();throw WorkbenchError.invalid(b.diagnostics)}
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let connection=MCPConnection();try await connection.start(executable:source.appendingPathComponent(".build/debug/WampumController"),arguments:["--state-dir",m.store.directory.path],directory:root,localOnly:true)
        let handoff=try await liveCall("wampum_context",model:m,connection:connection);XCTAssertTrue(handoff.pretty.contains("CLIENT_A"));XCTAssertFalse(handoff.pretty.contains("PRIVATE CLIENT"))
        let request=try await liveCall("wampum_request_observation",model:m,connection:connection)
        let ticket=try XCTUnwrap(request["ticket"]?.string);XCTAssertFalse(request.pretty.contains("Evidence pending"))
        m.controller.shareObservation()
        let observation=try await liveCall("wampum_read_observation",.object(["ticket":.string(ticket)]),model:m,connection:connection)
        let text=try XCTUnwrap(observation["snapshot"]?.string)
        let line=try XCTUnwrap(text.components(separatedBy:"\n").first{$0.contains("button \"Record evidence\"")})
        let start=try XCTUnwrap(line.range(of:"[ref="));let end=try XCTUnwrap(line[start.upperBound...].firstIndex(of:"]"));let target=String(line[start.upperBound..<end])
        let proposal=try await liveCall("wampum_propose_browser_action",.object(["tool":.string("browser_click"),"arguments":.object(["target":.string(target)]),"reason":.string("Click the local fixture evidence button once")]),model:m,connection:connection)
        let actionTicket=try XCTUnwrap(proposal["ticket"]?.string);XCTAssertFalse(b.busy)
        let call=try XCTUnwrap(b.proposed);b.execute(call,model:m)
        for _ in 0..<800 {if !b.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertTrue(b.snapshot.contains("Evidence recorded 742"),b.diagnostics)
        let status=try await liveCall("wampum_status",model:m,connection:connection)
        XCTAssertTrue(status["actions"]?[actionTicket]?.string?.contains("succeeded")==true,status.pretty)
        _=try await liveCall("wampum_stop",model:m,connection:connection);XCTAssertFalse(m.controller.enabled)
        await connection.stop();await b.connection.stop()
        print("CONTROLLER LIVE: real stdio helper -> scoped handoff -> reviewed observation -> queued browser click -> operator execution -> status -> revoke passed; no external model provider contacted")
    }

}
