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
    @MainActor func testReviewedMultiFilePatchAppliesThroughWorkbenchAndOpensChangedFiles() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["git","init","-q"];process.currentDirectoryURL=root;try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("docs"),withIntermediateDirectories:true)
        try Data("old line\n".utf8).write(to:root.appendingPathComponent("README.md"));m.openFile("README.md")
        try Data("legacy integration\n".utf8).write(to:root.appendingPathComponent("legacy.js"))
        let diff="""
        diff --git a/README.md b/README.md
        index 4a7f2b4..a4d7d8e 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -old line
        +new line
        diff --git a/docs/guide.md b/docs/guide.md
        new file mode 100644
        index 0000000..3e75765
        --- /dev/null
        +++ b/docs/guide.md
        @@ -0,0 +1 @@
        +Guide
        WAMPUM DELETE FILE: legacy.js
        """

        m.stagePatch("```diff\n"+diff+"\n```")
        XCTAssertTrue(m.showPatchReview,m.error ?? "Patch review did not open")
        XCTAssertEqual(m.patchPaths,["README.md","docs/guide.md (new file)","legacy.js (delete)"])
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("README.md"),encoding:.utf8),"old line\n")
        m.applyReviewedPatch()

        XCTAssertFalse(m.showPatchReview)
        XCTAssertNil(m.error)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("README.md"),encoding:.utf8),"new line\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("docs/guide.md"),encoding:.utf8),"Guide\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("legacy.js").path))
        XCTAssertTrue(m.editorDocuments.contains{$0.path=="docs/guide.md" && !$0.dirty})
        XCTAssertTrue(m.status.contains("backed up"))
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
    @MainActor func testEmptyModelReplyIsReportedWithoutSavingPlaceholder() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let script = #"""
import http.server,json
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.dumps({'message':{'content':''},'prompt_eval_count':8,'eval_count':0,'done_reason':'stop'}).encode()
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H);s.timeout=10;print(s.server_port,flush=True);s.handle_request();s.server_close()
"""#
        let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["-u","-c",script]
        let pipe=Pipe();server.standardOutput=pipe;server.standardError=FileHandle.nullDevice;try server.run()
        defer{if server.isRunning{server.terminate()}}
        var line=Data()
        while !line.contains(10){guard let byte=try pipe.fileHandleForReading.read(upToCount:1),!byte.isEmpty else{throw WorkbenchError.invalid("Empty-reply fixture failed to start")};line.append(byte)}
        let port=String(decoding:line,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let model=WorkbenchModel(stateDirectory:root.appendingPathComponent("state"),ollamaBase:URL(string:"http://127.0.0.1:\(port)")!)
        model.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))]
        model.session.model="fixture-qwen";model.session.prompt="Return one short answer.";model.send()
        XCTAssertTrue(model.showRequestReview);model.sendReviewedRequest()
        for _ in 0..<100 {if !model.busy{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.session.messages.map(\.role),["user"])
        XCTAssertFalse(model.session.messages.contains{$0.content.contains("No answer content returned")})
        XCTAssertTrue(model.status.contains("Local model returned no answer text"),model.status)
        XCTAssertTrue(model.contextStatus.contains("output: 0"),model.contextStatus)
    }
    @MainActor func testSourceReviewFreezesExactDraftsForQuoteCheck() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("The preview leaves wallet actions offline.".utf8).write(to:root.appendingPathComponent("release.md"))
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))]
        m.session.model="fixture-qwen";m.session.prompt="Review the release.";m.openFile("release.md");m.evidenceReviewMode=true
        m.output="Build output: published 9 files.\nExit: 0";m.attachOutput()
        m.send()

        XCTAssertEqual(m.pendingSourceQuoteSources?["release.md"],"The preview leaves wallet actions offline.")
        XCTAssertEqual(m.pendingSourceQuoteSources?["CHECK OUTPUT 1"],"Build output: published 9 files.\nExit: 0")
        XCTAssertTrue(m.requestPreview.contains("CHECK OUTPUT 1 (untrusted evidence)"))
        XCTAssertTrue(m.requestPreview.contains("never claim a listed-but-unattached file was reviewed"))
        m.cancelRequestReview()
        XCTAssertNil(m.pendingSourceQuoteSources)

        m.evidenceReviewMode=false;m.send()
        XCTAssertNil(m.pendingSourceQuoteSources)
    }
    @MainActor func testActiveEditorIsDefaultAndAllTabsAreOptIn()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("facts.md");try Data("Verified project fact: board mode is Ocean.".utf8).write(to:file)
        try Data("Verified project limitation: no deployment has been confirmed.".utf8).write(to:root.appendingPathComponent("release.md"))
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))];m.session.model="fixture-qwen";m.session.prompt="Review the supplied project facts.";m.openFile("facts.md");m.openFile("release.md")
        m.session.messages=[ChatMessage(role:"user",content:"old question"),ChatMessage(role:"assistant",content:"Old unsupported claim")]
        XCTAssertTrue(m.includeEditor);XCTAssertFalse(m.includeOpenFiles);m.send();XCTAssertTrue(m.showRequestReview)
        XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [release.md]"));XCTAssertTrue(m.requestPreview.contains("Verified project limitation: no deployment has been confirmed."));XCTAssertFalse(m.requestPreview.contains("Verified project fact: board mode is Ocean."));XCTAssertTrue(m.requestPreview.contains("Old unsupported claim"));XCTAssertFalse(m.requestPreview.contains("EVIDENCE REVIEW MODE"));XCTAssertFalse(m.requestPreview.contains(root.path))
        m.cancelRequestReview();m.includeOpenFiles=true;m.send();XCTAssertTrue(m.requestPreview.contains("Verified project limitation: no deployment has been confirmed."));XCTAssertTrue(m.requestPreview.contains("Verified project fact: board mode is Ocean."));XCTAssertTrue(m.requestPreview.contains("Old unsupported claim"))
        m.cancelRequestReview();m.includeOpenFiles=true;m.evidenceReviewMode=true;m.send();XCTAssertTrue(m.requestPreview.contains("EVIDENCE REVIEW MODE"));XCTAssertFalse(m.requestPreview.contains("Old unsupported claim"));XCTAssertTrue(m.requestPreview.contains("Prior conversation is excluded"));XCTAssertTrue(m.requestPreview.contains("facts.md"));XCTAssertTrue(m.requestPreview.contains("release.md"))
        m.cancelRequestReview();m.includeEditor=false;m.send();XCTAssertFalse(m.requestPreview.contains("Verified project fact: board mode is Ocean."));XCTAssertFalse(m.requestPreview.contains("Verified project limitation: no deployment has been confirmed."));XCTAssertTrue(m.requestPreview.contains("Old unsupported claim"))
    }
    @MainActor func testOpenFilesContextHasExplicit128KLimit() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data(String(repeating:"x",count:128_001).utf8).write(to:root.appendingPathComponent("large.md"))
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))];m.session.model="fixture-qwen";m.session.prompt="Review this file.";m.openFile("large.md");m.includeOpenFiles=true
        m.send();XCTAssertFalse(m.showRequestReview);XCTAssertNil(m.pendingPacket);XCTAssertTrue(m.error?.contains("exceeds 128 KB") == true)
    }
    @MainActor func testProjectRefreshLoadsFilesAndExplainsEmptyFolder() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let project=root.appendingPathComponent("project");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true);m.session.project=project.path
        m.refreshFiles();XCTAssertTrue(m.files.isEmpty)
        XCTAssertTrue(m.status.contains("No files found"))
        try Data("print('ready')".utf8).write(to:project.appendingPathComponent("main.py"))
        m.refreshFiles()
        XCTAssertEqual(m.files,["main.py"])
        XCTAssertTrue(m.status.contains("Project files loaded: 1"))
    }
    @MainActor func testBuildFromMarkdownPreparesProjectPatchRequest() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("# Build task\nImplement the requested feature.".utf8).write(to:root.appendingPathComponent("BUILD.md"))
        try Data("print(\"app\")".utf8).write(to:root.appendingPathComponent("main.py"))
        try Data("notes".utf8).write(to:root.appendingPathComponent("notes.txt"))
        try Data("LOCK CONTENT".utf8).write(to:root.appendingPathComponent("package-lock.json"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("vendor"),withIntermediateDirectories:true)
        try Data("VENDORED CONTENT".utf8).write(to:root.appendingPathComponent("vendor/library.js"))
        m.openFile("BUILD.md");m.evidenceReviewMode=true;m.includeOpenFiles=false;m.session.context=8192
        m.buildFromMarkdownBrief()
        XCTAssertFalse(m.evidenceReviewMode);XCTAssertTrue(m.includeEditor);XCTAssertFalse(m.includeOpenFiles)
        XCTAssertEqual(m.session.context,32768);XCTAssertTrue(m.session.prompt.contains("complete unified Git diff"));XCTAssertTrue(m.session.prompt.contains("standard `diff --git a/path b/path` header"));XCTAssertTrue(m.session.prompt.contains("Preserve existing behavior unless the brief explicitly asks to change it"))
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))]
        m.session.model="fixture-qwen";m.send()
        XCTAssertTrue(m.showRequestReview);XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [BUILD.md]"));XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [main.py]"))
        XCTAssertFalse(m.requestPreview.contains("LOCK CONTENT"));XCTAssertFalse(m.requestPreview.contains("VENDORED CONTENT"));XCTAssertFalse(m.requestPreview.contains("EVIDENCE REVIEW MODE"))
        XCTAssertTrue(m.status.contains("Review & Send"))
    }
    @MainActor func testBuildFromMarkdownPrioritizesApplicationAndBuildFilesWithinContext() throws {
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("# Build\nEdit main.html and src/large.js.".utf8).write(to:root.appendingPathComponent("BUILD.md"))
        try Data(String(repeating:"H",count:70_000).utf8).write(to:root.appendingPathComponent("main.html"))
        try Data("{\"scripts\":{\"build\":\"node scripts/build-site.js\"}}".utf8).write(to:root.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("scripts"),withIntermediateDirectories:true)
        try Data(String(repeating:"B",count:7_000).utf8).write(to:root.appendingPathComponent("scripts/build-site.js"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("src"),withIntermediateDirectories:true)
        try Data(String(repeating:"S",count:12_000).utf8).write(to:root.appendingPathComponent("src/large.js"))
        m.openFile("BUILD.md");m.session.model="fixture-qwen"
        m.models=[try JSONDecoder().decode(LocalModel.self,from:Data("{\"name\":\"fixture-qwen\"}".utf8))]
        m.buildFromMarkdownBrief();m.send()
        XCTAssertTrue(m.showRequestReview,m.error ?? "Build request preview did not open")
        XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [main.html]"))
        XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [package.json]"))
        XCTAssertTrue(m.requestPreview.contains("UNTRUSTED EDITOR [scripts/build-site.js]"))
        XCTAssertFalse(m.requestPreview.contains("UNTRUSTED EDITOR [src/large.js]"))
        XCTAssertTrue(m.requestPreview.contains("SOURCE PATHS NOT ATTACHED"))
    }
    @MainActor func testProxyReviewFreezesWithoutSending()throws{
        let(root,m)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        m.privacy.proxyURL="http://127.0.0.1:8080";m.externalURL="https://example.test/inspect";m.prepareProxyProbe();m.externalURL="https://other.example.test/"
        XCTAssertEqual(m.pendingProbe?.url.host,"example.test");XCTAssertTrue(m.showProbeReview);XCTAssertFalse(m.probing);XCTAssertEqual(m.probeOutput,"No external request made.");m.cancelProxyProbe();XCTAssertNil(m.pendingProbe)
    }

}
