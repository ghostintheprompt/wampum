import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class EditorTabTests: XCTestCase {
    @MainActor func fixture() throws -> (URL, WorkbenchModel) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("disk A".utf8).write(to:root.appendingPathComponent("a.txt"))
        try Data("disk B".utf8).write(to:root.appendingPathComponent("b.txt"))
        let model=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"));model.session.project=root.path
        return (root,model)
    }
    @MainActor func testMultipleDraftsSwitchRestartAndSaveOnlyActiveFile() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.session.draft="draft A";m.openFile("b.txt");m.session.draft="draft B";m.persist()
        let restored=WorkbenchModel(stateDirectory:m.store.directory)
        XCTAssertEqual(restored.editorDocuments.map(\.path),["a.txt","b.txt"])
        XCTAssertEqual(restored.session.file,"b.txt");XCTAssertEqual(restored.session.draft,"draft B")
        restored.openFile("a.txt");XCTAssertEqual(restored.session.draft,"draft A");restored.saveFile()
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("a.txt")),"draft A")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("b.txt")),"disk B")
        XCTAssertFalse(restored.dirty);XCTAssertTrue(restored.editorDocuments.first{$0.path=="b.txt"}!.dirty)
        restored.openFile("b.txt");XCTAssertEqual(restored.session.draft,"draft B");XCTAssertNil(restored.error)
    }
    @MainActor func testExternalEditBlocksSaveAndCloseWithoutLosingEitherVersion() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.session.draft="my draft";m.openFile("b.txt")
        try Data("outside edit".utf8).write(to:root.appendingPathComponent("a.txt"))
        m.saveAndCloseTab("a.txt")
        XCTAssertNotNil(m.error);XCTAssertEqual(m.session.file,"b.txt")
        XCTAssertEqual(m.editorDocuments.first{$0.path=="a.txt"}?.draft,"my draft")
        XCTAssertEqual(m.editorDocuments.first{$0.path=="a.txt"}?.original,"disk A")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("a.txt")),"outside edit")
        m.openFile("a.txt");XCTAssertEqual(m.session.draft,"my draft")
    }
    @MainActor func testDirtyCloseRequiresChoiceAndDiscardRetainsCheckpoint() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.session.draft="recover this";m.openFile("b.txt");m.session.draft="keep B"
        m.requestCloseTab("a.txt");XCTAssertEqual(m.pendingCloseTab,"a.txt");XCTAssertEqual(m.editorDocuments.count,2)
        m.closeEditorTab("a.txt");XCTAssertEqual(m.editorDocuments.count,2)
        m.error=nil;m.closeEditorTab("a.txt",discardChanges:true)
        XCTAssertEqual(m.editorDocuments.map(\.path),["b.txt"]);XCTAssertEqual(m.session.draft,"keep B")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("a.txt")),"disk A")
        let files=try FileManager.default.contentsOfDirectory(at:m.store.directory.appendingPathComponent("checkpoints"),includingPropertiesForKeys:nil)
        let checkpoints=try files.map{try JSONDecoder().decode(Session.self,from:Data(contentsOf:$0))}
        XCTAssertTrue(checkpoints.contains{$0.editorDocuments.contains{$0.path=="a.txt" && $0.draft=="recover this"}})
        let restored=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertEqual(restored.editorDocuments.map(\.path),["b.txt"])
        XCTAssertNil(m.error)
    }
    @MainActor func testBackgroundSaveAndCloseDoesNotSaveOrSelectOtherDraft() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.session.draft="save A";m.openFile("b.txt");m.session.draft="unsaved B"
        m.saveAndCloseTab("a.txt")
        XCTAssertEqual(m.session.file,"b.txt");XCTAssertEqual(m.session.draft,"unsaved B")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("a.txt")),"save A")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("b.txt")),"disk B")
        XCTAssertEqual(m.editorDocuments.count,1);XCTAssertTrue(m.dirty)
    }
    @MainActor func testCleanCloseSelectsNeighbourAndLastCloseRestoresEmptyEditor() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.openFile("b.txt");m.requestCloseTab("b.txt")
        XCTAssertEqual(m.session.file,"a.txt");XCTAssertNil(m.pendingCloseTab)
        m.requestCloseTab("a.txt");XCTAssertTrue(m.session.file.isEmpty);XCTAssertTrue(m.editorDocuments.isEmpty)
        let restored=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertTrue(restored.editorDocuments.isEmpty)
    }
    @MainActor func testStorageFailureAbortsSwitchDiscardAndProposalReplacement() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.openFile("a.txt");m.session.draft="irreplaceable"
        let storage=m.store.directory.appendingPathComponent("session.json")
        try FileManager.default.removeItem(at:storage);try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:false)
        m.openFile("b.txt");XCTAssertEqual(m.session.file,"a.txt");XCTAssertEqual(m.session.draft,"irreplaceable")
        m.closeEditorTab("a.txt",discardChanges:true);XCTAssertEqual(m.editorDocuments.count,1)
        m.proposal="replacement";m.showProposal=true;m.applyProposal()
        XCTAssertEqual(m.session.draft,"irreplaceable");XCTAssertTrue(m.showProposal);XCTAssertNotNil(m.error)
    }
    @MainActor func testLegacySessionMigrationAndMissingFileDraftRecovery() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var old=Session();old.project=root.path;old.file="a.txt";old.original="disk A";old.draft="legacy draft"
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any];object.removeValue(forKey:"editorTabs")
        try JSONSerialization.data(withJSONObject:object).write(to:m.store.directory.appendingPathComponent("session.json"))
        let restored=WorkbenchModel(stateDirectory:m.store.directory);restored.openFile("b.txt")
        try FileManager.default.removeItem(at:root.appendingPathComponent("a.txt"))
        restored.openFile("a.txt");XCTAssertEqual(restored.session.draft,"legacy draft");XCTAssertFalse(restored.saveEditorTab("a.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(restored.editorDocuments.count,2)
    }
    @MainActor func testScenarioTabsStayIsolatedAcrossRestart() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let entries=try ["A","B"].map { id -> LabEntry in
            let folder=root.appendingPathComponent(id);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data(id.utf8).write(to:folder.appendingPathComponent("notes.txt"))
            return LabEntry(id:id,title:id,mode:"fixture",status:"unverified",folder:folder.path)
        }
        let index=root.appendingPathComponent("index.json");try JSONEncoder().encode(entries).write(to:index);m.importScenarios(from:index)
        m.openFile("a.txt");m.session.draft="general draft"
        m.switchScenario("A");m.openFile("notes.txt");m.session.draft="A draft"
        m.switchScenario("B");XCTAssertTrue(m.editorDocuments.isEmpty);m.openFile("notes.txt");m.session.draft="B draft";m.persist()
        let restored=WorkbenchModel(stateDirectory:m.store.directory);XCTAssertEqual(restored.session.draft,"B draft")
        restored.switchScenario("A");XCTAssertEqual(restored.session.draft,"A draft");XCTAssertEqual(restored.editorDocuments.count,1)
        restored.switchScenario(nil);XCTAssertEqual(restored.session.draft,"general draft");XCTAssertEqual(restored.session.file,"a.txt")
        XCTAssertNil(restored.error)
    }
}
