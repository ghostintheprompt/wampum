import XCTest
@testable import Wampum
@testable import WorkbenchCore
final class AppTests:XCTestCase {
    @MainActor func fixture()throws->(URL,WorkbenchModel){let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);let model=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));model.session.project=root.path;return(root,model)}
    @MainActor func testContinuationPreservesUnsentPromptAndRequiresLatestReply() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var answer=ChatMessage(role:"assistant",content:"# Partial\n")
        answer.stopReason="length";answer.outputTokens=1024
        m.session.messages=[answer];m.session.prompt="unsent work"
        m.prepareContinuation(answer);XCTAssertEqual(m.session.prompt,"unsent work")
        m.session.prompt="";m.error=nil;m.prepareContinuation(answer)
        XCTAssertTrue(m.session.prompt.contains("exactly where it stopped"));XCTAssertFalse(m.busy);XCTAssertFalse(m.showRequestReview)
        let restored=try m.store.load()
        XCTAssertEqual(restored.messages.last?.stopReason,"length")
        XCTAssertEqual(restored.messages.last?.outputTokens,1024)
    }
    @MainActor func testProposalStagesWithoutWritingThenSaves()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("case.txt");try Data("before".utf8).write(to:file);m.openFile("case.txt")
        m.stageProposal("Complete file:\n```text\nafter\n```");XCTAssertTrue(m.showProposal);m.applyProposal()
        XCTAssertEqual(try String(contentsOf:file),"before");XCTAssertEqual(m.session.draft,"after\n");m.saveFile();XCTAssertEqual(try String(contentsOf:file),"after\n");XCTAssertNil(m.error)
    }
    @MainActor func testDraftSwitchAndRestoreFromDisk()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("a".utf8).write(to:root.appendingPathComponent("a"));try Data("b".utf8).write(to:root.appendingPathComponent("b"));m.openFile("a");m.session.draft="unsaved";m.openFile("b")
        let checkpoints=try FileManager.default.contentsOfDirectory(at:m.store.directory.appendingPathComponent("checkpoints"),includingPropertiesForKeys:nil)
        let sessions=try checkpoints.map{try JSONDecoder().decode(Session.self,from:Data(contentsOf:$0))}
        XCTAssertTrue(sessions.contains{$0.file=="a" && $0.draft=="unsaved"});XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("a")),"a")
        m.session.notes="handoff";m.persist();let restored=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertEqual(restored.session.notes,"handoff");XCTAssertEqual(restored.session.file,"b")
    }
    @MainActor func testCheckProgressAppearsBeforeProcessFinishes() async throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.command="printf 'PHASE_ONE'; sleep 2; printf 'PHASE_TWO'";m.runCheck()
        for _ in 0..<30 {if m.output.hasSuffix("PHASE_ONE"){break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertTrue(m.running);XCTAssertTrue(m.output.hasSuffix("PHASE_ONE"))
        for _ in 0..<60 {if !m.running{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertFalse(m.running);XCTAssertTrue(m.output.contains("PHASE_TWO"));XCTAssertEqual(m.output.components(separatedBy:"PHASE_ONE").count,3)
    }
    @MainActor func testActualCheckCapturesNonzeroExit()async throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.command="printf 'WAMPUM_FIXTURE'; exit 7";m.runCheck()
        for _ in 0..<100 {if !m.running{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertFalse(m.running);XCTAssertTrue(m.output.contains("WAMPUM_FIXTURE"));XCTAssertTrue(m.output.contains("Exit: 7"));m.attachOutput();XCTAssertTrue(m.session.prompt.contains("Exit: 7"))
    }
    @MainActor func testExternalWarningFreezesCommandWithoutRunning()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.command="printf original";m.requestExternalRun();m.command="printf changed"
        XCTAssertEqual(m.pendingNetworkCommand,"printf original");XCTAssertTrue(m.showNetworkConfirmation);XCTAssertFalse(m.running);XCTAssertEqual(m.output,"No check run yet.");m.cancelExternalRun();XCTAssertEqual(m.pendingNetworkCommand,"");XCTAssertFalse(m.showNetworkConfirmation)
    }
    @MainActor func testCorruptSessionRecoveryCopy()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        try Data("corrupt".utf8).write(to:root.appendingPathComponent("session.json"));let m=WorkbenchModel(stateDirectory:root);XCTAssertNotNil(m.error);m.persist()
        let recovery=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("recovery-")};XCTAssertEqual(recovery.count,1);XCTAssertEqual(try String(contentsOf:recovery[0]),"corrupt")
    }
    @MainActor func testMaskedModelPreviewKeepsOriginalLocal()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))];m.session.model="fixture-qwen";m.session.prompt="Client Example api_key=PRIVATE123456";m.privacy.aliasRules="Client Example => CLIENT_A";m.send()
        XCTAssertTrue(m.showRequestReview);XCTAssertTrue(m.requestPreview.contains("CLIENT_A"));XCTAssertFalse(m.requestPreview.contains("Client Example"));XCTAssertFalse(m.requestPreview.contains("PRIVATE123456"));XCTAssertEqual(m.session.prompt,"Client Example api_key=PRIVATE123456");XCTAssertTrue(m.session.messages.isEmpty);XCTAssertFalse(m.busy);m.cancelRequestReview();XCTAssertNil(m.pendingPacket)
    }
    @MainActor func testProxyReviewFreezesWithoutSending()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.privacy.proxyURL="http://127.0.0.1:8080";m.externalURL="https://example.test/inspect";m.prepareProxyProbe();m.externalURL="https://other.example.test/"
        XCTAssertEqual(m.pendingProbe?.url.host,"example.test");XCTAssertTrue(m.showProbeReview);XCTAssertFalse(m.probing);XCTAssertEqual(m.probeOutput,"No external request made.");m.cancelProxyProbe();XCTAssertNil(m.pendingProbe)
    }

}
