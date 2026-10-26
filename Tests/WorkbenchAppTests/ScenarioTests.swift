import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class ScenarioTests:XCTestCase {
    @MainActor func fixture() throws -> (URL,WorkbenchModel) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let entries=try ["BB1S1","WB2S5"].map { id -> LabEntry in
            let folder=root.appendingPathComponent(id);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            return LabEntry(id:id,title:id,mode:id.hasPrefix("BB") ? "black_box":"white_box",status:"unverified",folder:folder.path)
        }
        let index=root.appendingPathComponent("INDEX.json");try JSONEncoder().encode(entries).write(to:index)
        let model=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));model.importScenarios(from:index)
        return(root,model)
    }
    @MainActor func testScenarioIsolationRestartAndGeneralRecovery() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.session.notes="general notes";m.session.draft="general unsaved draft"
        m.switchScenario("BB1S1");m.session.lab?.markers="A_ONLY";m.session.messages=[ChatMessage(role:"user",content:"A private conversation")];m.session.draft="A unsaved draft";m.session.prompt="A pending prompt";m.session.scope="A scope"
        m.switchScenario("WB2S5");XCTAssertTrue(m.session.messages.isEmpty);XCTAssertEqual(m.session.lab?.markers,"");XCTAssertEqual(m.session.scope,"")
        m.session.lab?.markers="B_ONLY";m.persist()
        let restarted=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertEqual(restarted.session.lab?.id,"WB2S5");XCTAssertEqual(restarted.labs.count,2)
        restarted.switchScenario("BB1S1");XCTAssertEqual(restarted.session.draft,"A unsaved draft");XCTAssertEqual(restarted.session.prompt,"A pending prompt");XCTAssertEqual(restarted.session.lab?.markers,"A_ONLY");XCTAssertEqual(restarted.session.messages.count,1);XCTAssertEqual(restarted.session.scope,"A scope")
        restarted.switchScenario(nil);XCTAssertEqual(restarted.session.notes,"general notes");XCTAssertEqual(restarted.session.draft,"general unsaved draft");XCTAssertNil(restarted.session.lab);XCTAssertNil(restarted.error)
    }
    @MainActor func testActiveMemoryIncludedWithoutOtherScenario() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.switchScenario("BB1S1");m.session.lab?.markers="ONLY_A_MARKER";m.switchScenario("WB2S5");m.session.lab?.markers="ONLY_B_MARKER"
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture\"}".utf8))];m.session.model="fixture";m.session.prompt="What evidence is missing?";m.send()
        XCTAssertTrue(m.showRequestReview);XCTAssertTrue(m.requestPreview.contains("ONLY_B_MARKER"));XCTAssertFalse(m.requestPreview.contains("ONLY_A_MARKER"));XCTAssertTrue(m.requestPreview.contains("operator-maintained notes"));XCTAssertFalse(m.busy)
        m.switchScenario("BB1S1");XCTAssertEqual(m.session.lab?.id,"WB2S5");m.cancelRequestReview()
    }
    @MainActor func testCorruptScenarioPreservedAndSwitchAborted() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.switchScenario("BB1S1");m.switchScenario("WB2S5")
        let file=m.store.directory.appendingPathComponent("scenarios/BB1S1.json");try Data("broken".utf8).write(to:file)
        m.switchScenario("BB1S1");XCTAssertEqual(m.session.lab?.id,"WB2S5");XCTAssertEqual(try String(contentsOf:file),"broken");XCTAssertNotNil(m.error)
    }
    @MainActor func testBoundedSourceNotesImport() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.switchScenario("BB1S1");let folder=URL(fileURLWithPath:m.session.project)
        try Data("Brief fixture".utf8).write(to:folder.appendingPathComponent("BRIEF.md"))
        try Data("Observed state fixture".utf8).write(to:folder.appendingPathComponent("STATE.md"))
        m.loadScenarioNotes();XCTAssertTrue(m.session.notes.contains("Observed state fixture"));let original=m.session.notes
        try Data(String(repeating:"x",count:13000).utf8).write(to:folder.appendingPathComponent("STATE.md"));m.loadScenarioNotes()
        XCTAssertEqual(m.session.notes,original);XCTAssertNotNil(m.error)
    }
    @MainActor func testLiveScenarioMemoryAfterHistoryEviction() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_SCENARIO_LIVE"] == "1" else {throw XCTSkip("Opt-in local scenario-memory inference.")}
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.switchScenario("BB1S1");m.session.lab?.markers="FIXTURE_REED_918";m.session.lab?.nextStep="Inspect the current environment; no live browser observation exists."
        m.models=try await m.client.models();m.session.model="lukey03/Qwen3.5-9B-abliterated:latest";m.session.context=4096
        m.session.messages=[ChatMessage(role:"user",content:String(repeating:"Old synthetic attempt. ",count:1000)),ChatMessage(role:"assistant",content:"Historical fixture only.")]
        m.session.prompt="Return only the observed marker from ACTIVE SCENARIO memory.";m.send()
        let packet=try XCTUnwrap(m.pendingPacket);XCTAssertEqual(packet.omitted,2)
        let reply=try await m.client.chat(model:m.session.model,packet:packet,context:4096,thinking:false,supportsThinking:true)
        XCTAssertTrue(reply.message.content.contains("FIXTURE_REED_918"))
        print("SCENARIO LIVE: older messages omitted=\(packet.omitted), prompt_tokens=\(reply.prompt_eval_count ?? -1), answer=\(reply.message.content.prefix(100))")
    }
    @MainActor func testRejectedToolsSurviveRestartAndConversationReset() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.switchScenario("BB1S1");m.session.lab?.rejectedTools="browser_snapshot: permission denied. Retry only after operator grant."
        m.session.messages=[];m.persist()
        let restored=WorkbenchModel(stateDirectory:m.store.directory)
        XCTAssertTrue(restored.session.lab?.context.contains("browser_snapshot: permission denied") == true)
        XCTAssertTrue(restored.session.lab?.context.contains("not a renamed tool") == true)
        restored.switchScenario("WB2S5");XCTAssertNil(restored.session.lab?.rejectedTools)
        restored.switchScenario("BB1S1");XCTAssertTrue(restored.session.lab?.rejectedTools?.contains("operator grant") == true)
        var old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(restored.session.lab!)) as! [String:Any]
        old.removeValue(forKey:"rejectedTools")
        XCTAssertNil(try JSONDecoder().decode(LabMemory.self,from:JSONSerialization.data(withJSONObject:old)).rejectedTools)
    }
    func testLegacySessionAndInvalidIDs() throws {
        var session=Session();session.notes="legacy"
        let encoded=try JSONEncoder().encode(session)
        var object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any];object.removeValue(forKey:"lab")
        let restored=try JSONDecoder().decode(Session.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertNil(restored.lab);XCTAssertEqual(restored.notes,"legacy")
        let store=ScenarioStore(directory:FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try store.load("../escape"))
    }
}
