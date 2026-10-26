import XCTest
@testable import WorkbenchCore

final class ControllerTests:XCTestCase {
    func request(token:String="fixture-token",client:String="A",tool:String="wampum_status",date:Date=Date())->ControllerRequest{ControllerRequest(clientID:client,clientName:"fixture",token:token,tool:tool,arguments:.object([:]),createdAt:date)}
    func testLeaseOwnershipScopeExpiryAndBudgets()throws {
        let now=Date();var lease=ControllerLease(token:"fixture-token",scenario:"BB1S1",context:"approved",now:now,seconds:10,maxCalls:2,maxActions:1,maxBytes:20)
        XCTAssertThrowsError(try lease.authorize(request(token:"wrong",date:now),scenario:"BB1S1",now:now));XCTAssertNil(lease.owner)
        try lease.authorize(request(date:now),scenario:"BB1S1",now:now);XCTAssertEqual(lease.owner,"A")
        XCTAssertThrowsError(try lease.authorize(request(client:"B",date:now),scenario:"BB1S1",now:now))
        XCTAssertThrowsError(try lease.authorize(request(date:now),scenario:"WB2S5",now:now))
        XCTAssertThrowsError(try lease.authorize(request(date:now),scenario:"BB1S1",now:now.addingTimeInterval(11)))
        try lease.reserveAction();XCTAssertThrowsError(try lease.reserveAction())
        try lease.account(.string("small"));XCTAssertThrowsError(try lease.account(.string(String(repeating:"x",count:30))))
        try lease.authorize(request(date:now),scenario:"BB1S1",now:now);XCTAssertThrowsError(try lease.authorize(request(date:now),scenario:"BB1S1",now:now))
        XCTAssertNoThrow(try lease.authorize(request(tool:"wampum_stop",date:now),scenario:"BB1S1",now:now))
    }
    func testStaleAndFutureRequestsRejected()throws {
        let now=Date();var lease=ControllerLease(token:"fixture-token",scenario:"lab",context:"reviewed",now:now)
        XCTAssertThrowsError(try lease.authorize(request(date:now.addingTimeInterval(-31)),scenario:"lab",now:now))
        XCTAssertThrowsError(try lease.authorize(request(date:now.addingTimeInterval(6)),scenario:"lab",now:now))
    }
    func testMailboxPrivateRoundTripAndOversize()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let box=ControllerMailbox(stateDirectory:root);try box.grant(token:"fixture-token")
        XCTAssertEqual(try box.access().token,"fixture-token")
        let attributes=try FileManager.default.attributesOfItem(atPath:box.accessURL.path);XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let r=request();try box.enqueue(r);XCTAssertEqual(try box.requests().first?.id,r.id)
        try box.respond(r,value:.object(["status":.string("reviewed")]));XCTAssertTrue(try box.requests().isEmpty);XCTAssertEqual(try box.response(r.id)?["status"]?.string,"reviewed");XCTAssertNil(try box.response(r.id))
        let oversized=ControllerRequest(clientID:"A",clientName:"fixture",token:"fixture-token",tool:"wampum_submit_checkpoint",arguments:.object(["text":.string(String(repeating:"x",count:70000))]));XCTAssertThrowsError(try box.enqueue(oversized))
        try box.revoke();XCTAssertThrowsError(try box.access())
    }
    func testActualControllerStdioAndFrozenCapability()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper=source.appendingPathComponent(".build/debug/WampumController")
        let box=ControllerMailbox(stateDirectory:root);try box.grant(token:"capability-A")
        let connection=MCPConnection();try await connection.start(executable:helper,arguments:["--state-dir",root.path],directory:root,localOnly:true)
        let tools=try await connection.tools();XCTAssertEqual(tools.count,7);XCTAssertFalse(tools.contains{$0.name.contains("execute") || $0.name.contains("shell")})
        let first=Task{try await connection.call(BrowserCall(name:"wampum_context",arguments:.object([:])))}
        var requests:[ControllerRequest]=[]
        for _ in 0..<100 {requests=try box.requests();if !requests.isEmpty{break};try await Task.sleep(nanoseconds:20_000_000)}
        let r=try XCTUnwrap(requests.first);XCTAssertEqual(r.token,"capability-A");try box.respond(r,value:.object(["context":.string("APPROVED_FIXTURE_ONLY")]))
        let result=try await first.value;XCTAssertTrue(result["content"]?.array?.first?["text"]?.string?.contains("APPROVED_FIXTURE_ONLY")==true)
        try box.grant(token:"capability-B")
        let second=Task{try await connection.call(BrowserCall(name:"wampum_status",arguments:.object([:])))}
        for _ in 0..<100 {requests=try box.requests();if !requests.isEmpty{break};try await Task.sleep(nanoseconds:20_000_000)}
        let stale=try XCTUnwrap(requests.first);XCTAssertEqual(stale.token,"capability-A","Existing controller must not silently acquire a new grant")
        try box.respond(stale,value:.object(["error":.string("old capability revoked")]))
        let denied=try await second.value;XCTAssertTrue(denied["isError"]?.isTrue==true)
        await connection.stop()
    }
}
