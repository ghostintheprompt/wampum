import XCTest
@testable import WorkbenchCore
final class CoreTests:XCTestCase {
    func fixture(_ body:(URL,Workspace)throws->Void)throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try body(root,Workspace(root:root))
    }
    func testTraversalRejected()throws{try fixture{_,w in XCTAssertThrowsError(try w.resolve("../outside"));XCTAssertThrowsError(try w.resolve("/etc/passwd"))}}
    func testSymlinkEscapeRejected()throws{try fixture{root,w in try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:URL(fileURLWithPath:"/etc"));XCTAssertThrowsError(try w.resolve("escape/passwd"))}}
    func testRoundTripAndBackup()throws{try fixture{root,w in let file=root.appendingPathComponent("case.md");try Data("before".utf8).write(to:file);let backups=root.appendingPathComponent("backups");try w.save("case.md",content:"after",expected:"before",backupDirectory:backups);XCTAssertEqual(try w.read("case.md"),"after");let saved=try FileManager.default.contentsOfDirectory(at:backups,includingPropertiesForKeys:nil);XCTAssertEqual(saved.count,1);XCTAssertEqual(try String(contentsOf:saved[0]),"before")}}
    func testStaleWritePreservesFile()throws{try fixture{root,w in try Data("external".utf8).write(to:root.appendingPathComponent("a"));XCTAssertThrowsError(try w.save("a",content:"overwrite",expected:"old",backupDirectory:root.appendingPathComponent("backups")));XCTAssertEqual(try w.read("a"),"external")}}
    func testCreateWithoutOverwrite()throws{try fixture{root,w in try w.save("new.md",content:"new",expected:nil,backupDirectory:root);XCTAssertThrowsError(try w.save("new.md",content:"oops",expected:nil,backupDirectory:root));XCTAssertEqual(try w.read("new.md"),"new")}}
    func testLargeAndBinaryFilesRejected()throws{try fixture{root,w in try Data(repeating:65,count:1_048_577).write(to:root.appendingPathComponent("large"));XCTAssertThrowsError(try w.read("large"));try Data([255,254,253]).write(to:root.appendingPathComponent("binary"));XCTAssertThrowsError(try w.read("binary"))}}
    func testSessionPersistsDraftAndTranscript()throws{try fixture{root,_ in let store=try SessionStore(directory:root.appendingPathComponent("state"));var s=Session();s.draft="unsaved work";s.original="original";s.notes="next action";s.messages=[ChatMessage(role:"user",content:"test")];try store.save(s);let loaded=try store.load();XCTAssertEqual(loaded.draft,s.draft);XCTAssertEqual(loaded.messages,s.messages);XCTAssertEqual(loaded.notes,"next action")}}
    func testCorruptSessionDoesNotDisappear()throws{try fixture{root,_ in let store=try SessionStore(directory:root);try Data("corrupt".utf8).write(to:root.appendingPathComponent("session.json"));XCTAssertThrowsError(try store.load());XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("session.json")),"corrupt")}}
    func testContextKeepsWholeRecentTurns()throws{let h=[ChatMessage(role:"user",content:String(repeating:"x",count:10000)),ChatMessage(role:"assistant",content:"old"),ChatMessage(role:"user",content:"current")];let p=try ContextPacket.build(system:"scope",history:h,context:4096);XCTAssertEqual(p.messages.last?["content"],"current");XCTAssertEqual(p.omitted,2)}
    func testOversizedCurrentPromptRejected()throws{XCTAssertThrowsError(try ContextPacket.build(system:"scope",history:[ChatMessage(role:"user",content:String(repeating:"x",count:20000))],context:4096))}
    func testRemoteOllamaRejected()throws{XCTAssertThrowsError(try OllamaClient(base:URL(string:"https://external.example")!));XCTAssertNoThrow(try OllamaClient())}
    func testInstalledModelNamePreserved()throws{let data=Data("{\"name\":\"lukey03/Qwen3.5-9B-abliterated\",\"size\":5600000000}".utf8);let m=try JSONDecoder().decode(LocalModel.self,from:data);XCTAssertEqual(m.name,"lukey03/Qwen3.5-9B-abliterated")}
}
