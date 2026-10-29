import SwiftUI
import AppKit
import WorkbenchCore

@main struct WampumApp: App {
    @StateObject private var model=WorkbenchModel()
    var body: some Scene {
        WindowGroup { WorkbenchView(model:model).frame(minWidth:1100,minHeight:720).preferredColorScheme(.dark) }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…", action: model.chooseProject).keyboardShortcut("o")
                Button("New File…", action: model.newFile).keyboardShortcut("n")
                Divider()
                Button("Save File", action: model.saveFile).keyboardShortcut("s")
                    .disabled(model.session.file.isEmpty)
                Menu("Export Markdown") {
                    Button("Latest Reply…") {
                        if let reply = model.session.messages.last(where: { $0.role == "assistant" }) {
                            model.saveMarkdownResponse(reply.content)
                        }
                    }.disabled(model.busy || !model.session.messages.contains(where: { $0.role == "assistant" }))
                    Button("All Replies…") { model.saveConversation(assistantOnly: true) }
                        .disabled(model.busy || !model.session.messages.contains(where: { $0.role == "assistant" }))
                    Button("Entire Chat…") { model.saveConversation() }
                        .disabled(model.busy || model.session.messages.isEmpty)
                }
                Divider()
                Button("Import Research Case Contract…", action: model.importResearchContract)
                    .disabled(model.busy || model.showRequestReview)
                Button("Capture Case Source…", action: model.captureCaseSource)
                    .disabled(model.busy || model.showRequestReview || model.session.researchCase == nil)
                Button("Review Case Memory…", action: model.importResearchLedger)
                    .disabled(model.busy || model.showRequestReview || model.session.researchCase == nil)
                Button("Inspect Case Coverage", action: model.inspectResearchCase)
                    .disabled(model.session.researchCase == nil)
                Button("Build Document from Sources…", action: model.prepareResearchDocument)
                    .disabled(model.busy || model.running || model.showRequestReview)
                Button("Review Document…", action: model.reviewDocumentCheck)
                    .disabled(model.busy || model.running || model.session.documentJob == nil)
                Divider()
                Button("Save Checkpoint", action: model.snapshot).keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Restore Checkpoint…", action: model.restoreCheckpoint)
            }
        }
    }
}
private let carbon=Color(red:0.075,green:0.075,blue:0.08)
private let panel=Color(red:0.105,green:0.105,blue:0.11)
private let acid=Color(red:0.76,green:0.83,blue:0.57)
struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var query=""
    @State private var detail="Qwen"
    @State private var documentReviewTab="Chapter"
    @State private var surface=ProcessInfo.processInfo.environment["WAMPUM_START_SURFACE"] == "Integrity" ? "Integrity":"Editor"
    var body: some View {
        VStack(spacing:0){
            HStack(spacing:14){Text("WAMPUM").font(.system(size:25,weight:.black,design:.rounded));Text("GHOST / RESEARCH").font(.system(size:12,weight:.medium,design:.monospaced)).foregroundStyle(acid);Divider().frame(height:22);Text("M4 / 16 GB").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary);Spacer();Picker("Workspace",selection:$surface){Text("Editor").tag("Editor");Text("Browser").tag("Browser");Text("Controller").tag("Controller");Text("Integrity").tag("Integrity")}.pickerStyle(.segmented).labelsHidden().frame(width:350);Button("Open Project",action:model.chooseProject);Button("Checkpoint",action:model.snapshot);Button("Restore",action:model.restoreCheckpoint)}.padding(14).background(panel)
            if surface=="Integrity" {IntegrityPanel(model:model.integrity).frame(maxWidth:.infinity,maxHeight:.infinity)} else if surface=="Controller" {ControllerPanel(model:model,openBrowser:{surface="Browser"}).frame(maxWidth:.infinity,maxHeight:.infinity)} else if surface=="Browser" {BrowserPanel(model:model,onOpenChat:{surface="Editor"}).frame(maxWidth:.infinity,maxHeight:.infinity)} else {
            HSplitView {
                VStack(alignment:.leading,spacing:10){
                    Text("EXPLORER").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(acid)
                    Text(model.session.project.isEmpty ? "No project selected" : URL(fileURLWithPath:model.session.project).lastPathComponent).font(.headline)
                    TextField("Filter files",text:$query).textFieldStyle(.roundedBorder)
                    List(model.files.filter{query.isEmpty || $0.localizedCaseInsensitiveContains(query)},id:\.self,selection:Binding<String?>(get:{model.session.file.isEmpty ? nil:model.session.file},set:{if let path=$0{model.openFile(path)}})){file in Text(file).font(.system(size:11,design:.monospaced)).lineLimit(2).tag(file)}.listStyle(.plain)
                    HStack{Button("New Case",action:model.newFile);Button("Refresh",action:model.refreshFiles)}
                    Text("First 2,000 nonhidden files. Binary files stay out of the editor.").font(.caption2).foregroundStyle(.secondary)
                }.padding(12).frame(minWidth:190,idealWidth:230,maxWidth:320).background(panel)
                VSplitView {
                    Group { if surface=="Browser" {BrowserPanel(model:model)} else {VStack(spacing:0){
                        EditorTabStrip(model:model)
                        HStack{Text(model.session.file.isEmpty ? "EDITOR" : model.session.file).font(.system(size:12,design:.monospaced));if model.dirty {Text("DRAFT").font(.caption2).foregroundStyle(acid)};Spacer();Button("Save",action:model.saveFile).disabled(model.session.file.isEmpty)}.padding(10).background(panel)
                        if model.session.file.isEmpty {VStack(alignment:.leading,spacing:18){Text("A place to build.\nA record of what held up.").font(.system(size:32,weight:.semibold));Text("Open a project, choose a file, and bring Qwen the context it actually needs.").foregroundStyle(.secondary);Button("Open a project…",action:model.chooseProject)}.frame(maxWidth:.infinity,maxHeight:.infinity).padding(36)}
                        else {CodeEditor(text:$model.session.draft).id(model.session.project+":"+model.session.file)}
                    }}}.frame(minHeight:270)
                    VStack(alignment:.leading,spacing:8){
                        HStack{Text("CHECK RUNNER / GUARDED").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(acid);Spacer();if model.running{Button("Stop",action:model.stopCheck)};Button("Attach Output to Prompt",action:model.attachOutput)}
                        HStack{TextField("Command in the selected project",text:$model.command).textFieldStyle(.roundedBorder).onSubmit{model.runCheck()};Button("Run Local"){model.runCheck()}.disabled(model.running || model.session.project.isEmpty)}
                        ScrollView{Text(model.output).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                        HStack{Button("Run with External Network…",action:model.requestExternalRun).disabled(model.running || model.session.project.isEmpty);Text("Local by default").foregroundStyle(acid)}
                        Text("Local mode restricts direct outgoing sockets. Local services may relay traffic. External access requires approval for each run.").font(.caption2).foregroundStyle(.secondary)
                    }.padding(12).frame(minHeight:150,idealHeight:210).background(panel)
                }.frame(minWidth:400)
                VStack(alignment:.leading,spacing:10){
                    Picker("Panel",selection:$detail){Text("Qwen").tag("Qwen");Text("Case Memory").tag("Case Memory");Text("Network").tag("Network");Text("Privacy").tag("Privacy")}.pickerStyle(.segmented)
                    if detail=="Privacy" {
                        Text("CONTENT MASKING").font(.headline).foregroundStyle(acid)
                        Toggle("Mask model requests",isOn:$model.privacy.maskModelRequests)
                        Toggle("Mask approved URL text",isOn:$model.privacy.maskExternalURLs)
                        Toggle("Detect common secret patterns",isOn:$model.privacy.detectSecrets)
                        Text("Exact aliases, one per line: real value => replacement. Rules and original transcripts stay on this Mac.").font(.caption)
                        TextEditor(text:$model.privacy.aliasRules).font(.system(size:12,design:.monospaced)).frame(minHeight:160)
                        Button("Save Privacy Settings",action:model.savePrivacy)
                        Text("Every model request gets a preview of the exact contents, including notes, history, and attached editor. Confirm before sending. Masked code can change behavior; review proposals before use.").font(.caption)
                        Text("Pattern detection is incomplete. This is masking, not encryption or a guarantee of anonymity. Network proxy settings live in Network and are independent.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }else if detail=="Network" {
                        Text("NETWORK GUARD").font(.headline).foregroundStyle(acid)
                        Text("No sign-in. No analytics SDK. No telemetry uploader. This ledger is stored locally.").font(.caption)
                        Text("Model requests: loopback only. Redirects refused. Commands: direct outgoing sockets restricted until a one-run grant.").font(.caption)
                        Text("Coverage limit: not a system-wide firewall. Local Ollama, DNS/system brokers, external apps, and allowed commands can relay traffic. MCP/browser enforcement is not implemented yet.").font(.caption).foregroundStyle(.secondary)
                        Text("APPROVED PROXY TOOL").font(.caption).foregroundStyle(acid)
                        TextField("HTTPS URL to inspect",text:$model.externalURL).textFieldStyle(.roundedBorder)
                        TextField("socks5://127.0.0.1:1080 or http://host:port",text:$model.privacy.proxyURL).textFieldStyle(.roundedBorder)
                        Button("Review HTTPS HEAD Request",action:model.prepareProxyProbe).disabled(model.probing)
                        Text(model.probeOutput).font(.caption2).textSelection(.enabled)
                        Text("Only this tool uses the configured proxy. No direct fallback. Shell commands, Ollama, browsers and MCP do not inherit it.").font(.caption2).foregroundStyle(.secondary)
                        Button("Refresh local activity",action:model.refreshNetwork)
                        ScrollView{LazyVStack(alignment:.leading,spacing:12){ForEach(model.networkEvents){event in VStack(alignment:.leading){Text(event.decision).font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(acid);Text(event.destination).font(.system(size:11,design:.monospaced));Text(event.component+" / "+event.detail).font(.caption2);Text(event.at,style:.time).font(.caption2).foregroundStyle(.secondary)}.textSelection(.enabled).padding(8).frame(maxWidth:.infinity,alignment:.leading).background(panel)}}}
                        Spacer()
                    }else if detail=="Case Memory"{
                        HStack { Text("LAB SCENARIOS").font(.caption).foregroundStyle(acid);Spacer();Button("Import Index…") {model.importScenarios()} }
                        Picker("Active",selection:Binding(get:{model.session.lab?.id ?? ""},set:{model.switchScenario($0.isEmpty ? nil:$0)})) {
                            Text("General workspace").tag("")
                            ForEach(model.labs) {lab in Text(lab.title).tag(lab.id)}
                        }.disabled(model.busy || model.running || model.showRequestReview)
                        if model.session.lab != nil {ScenarioMemoryView(model:model)}
                        Text("AUTHORIZED SCOPE").font(.caption).foregroundStyle(acid)
                        TextEditor(text:$model.session.scope).font(.system(size:12,design:.monospaced)).frame(minHeight:100)
                        Text("CHECKPOINT / HANDOFF").font(.caption).foregroundStyle(acid)
                        TextEditor(text:$model.session.notes).font(.system(size:12,design:.monospaced))
                        Text("Scope and notes are included with every request. Preserve objective, evidence, decisions, and next action here.").font(.caption).foregroundStyle(.secondary)
                    }else{
                        HStack{Picker("Model",selection:$model.session.model){Text("Choose installed model").tag("");ForEach(model.models){m in Text(m.name).tag(m.name)}}.labelsHidden();Button("Discover",action:model.discover).disabled(model.busy)}
                        Text(model.capabilities.isEmpty ? "Capabilities not loaded" : model.capabilities.joined(separator:" / ")).font(.caption2).foregroundStyle(.secondary)
                        HStack{Picker("Context",selection:$model.session.context){ForEach([4096,8192,16384,32768],id:\.self){Text("\($0/1024)K").tag($0)}};Toggle("Think",isOn:$model.thinking).disabled(!model.capabilities.contains("thinking"))}.font(.caption)
                        Text("8K starting profile. Larger contexts need measured memory headroom. No model downloads or global Ollama changes.").font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Menu("Export Markdown") {
                                Button("Entire Chat…") { model.saveConversation() }
                                Button("All Replies…") { model.saveConversation(assistantOnly: true) }
                            }.disabled(model.busy || model.session.messages.isEmpty)
                            Menu("Document") {
                                Button("Build from Sources…", action: model.prepareResearchDocument)
                                    .disabled(model.showRequestReview)
                                Button("Review Document…", action: model.reviewDocumentCheck)
                                    .disabled(model.session.documentJob == nil)
                            }.disabled(model.busy || model.running)
                        }
                        Text("Export saves existing messages. Build creates a document from a source manifest.")
                            .font(.caption2).foregroundStyle(.secondary)
                        ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:16){ForEach(model.session.messages){message in VStack(alignment:.leading,spacing:7){Text(message.role.uppercased()).font(.system(size:10,weight:.bold,design:.monospaced)).foregroundStyle(acid);Text(message.content).font(.system(size:13)).textSelection(.enabled);if let paths=message.imagePaths,!paths.isEmpty {Text("\(paths.count) image attachment(s) saved locally. Not resent automatically.").font(.caption2).foregroundStyle(.secondary)};if message.role=="assistant" {VStack(alignment:.leading,spacing:6){if message.stopReason == "length" {Text("INCOMPLETE — output limit reached").font(.caption.bold()).foregroundStyle(.orange)};if let tokens=message.outputTokens {Text("Output: \(tokens) tokens / stop: \(message.stopReason ?? "unknown")").font(.caption2).foregroundStyle(.secondary)};HStack{Button("Save Reply…"){model.saveMarkdownResponse(message.content)};if model.session.messages.last?.id == message.id {Button("Continue Reply"){model.prepareContinuation(message)}.disabled(model.busy || model.showRequestReview)}}}};if message.role=="assistant" && message.content.contains("```"){Button("Review File Proposal"){model.stageProposal(message.content)}}}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(panel).clipShape(RoundedRectangle(cornerRadius:8)).id(message.id)}}}.onChange(of:model.session.messages.count){_,_ in if let id=model.session.messages.last?.id{proxy.scrollTo(id,anchor:.bottom)}}}
                        Text(model.contextStatus).font(.caption2).foregroundStyle(.secondary)
                        Toggle("Include current editor in this request",isOn:$model.includeEditor).font(.caption)
                        ImageAttachmentTray(model:model)
                        TextEditor(text:$model.session.prompt).font(.system(size:13)).frame(height:100).overlay(RoundedRectangle(cornerRadius:5).stroke(.gray.opacity(0.4)))
                        HStack{Text("Saved locally. No sign-in.").font(.caption2).foregroundStyle(.secondary);Spacer();if model.busy{ProgressView().controlSize(.small);Button("Stop",action:model.stopGeneration)}else{Button("Review & Send",action:model.send).buttonStyle(.borderedProminent).tint(acid).foregroundStyle(.black).keyboardShortcut(.return,modifiers:.command)}}
                    }
                }.padding(12).frame(minWidth:330,idealWidth:400,maxWidth:600)
            }
            }
            HStack{Text(model.status).lineLimit(1);Spacer();Text("LOCAL INFERENCE / EXPLICIT CONTEXT / DISK CHECKPOINTS").font(.system(size:9,design:.monospaced))}.font(.caption).padding(8).background(panel)
        }.background(carbon).tint(acid)
        .task {while !Task.isCancelled {model.controller.poll(model:model);do{try await Task.sleep(nanoseconds:500_000_000)}catch{return}}}
        .onReceive(model.$session.debounce(for:.milliseconds(500),scheduler:RunLoop.main)){_ in model.persist()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in model.shutdown()}
        .onChange(of:detail){_,value in if value=="Network"{model.refreshNetwork()}}
        .confirmationDialog("Allow external network for this command?",isPresented:$model.showNetworkConfirmation,titleVisibility:.visible){Button("Allow for This Run",action:model.allowExternalRun);Button("Cancel",role:.cancel,action:model.cancelExternalRun)}message:{Text("This command and its children may contact any destination and transmit data accessible to your macOS account. The grant applies only to this run. Wampum cannot inspect every connection.\n\n"+model.pendingNetworkCommand)}
        .onChange(of:model.session.model){_,_ in Task{await model.inspectModel()}}
        .confirmationDialog("Close unsaved draft?",isPresented:Binding(get:{model.pendingCloseTab != nil},set:{if !$0{model.pendingCloseTab=nil}}),titleVisibility:.visible){
            if let path=model.pendingCloseTab {
                Button("Save and Close"){model.saveAndCloseTab(path)}
                Button("Discard Draft",role:.destructive){model.closeEditorTab(path,discardChanges:true)}
            }
            Button("Cancel",role:.cancel){model.pendingCloseTab=nil}
        }message:{Text("Save or discard \(model.pendingCloseTab ?? "this file"). Discard keeps a recovery checkpoint and does not change the project file.")}
        .alert("Workbench",isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})){Button("OK"){model.error=nil}}message:{Text(model.error ?? "")}
        .sheet(isPresented:$model.showSourceCoverage) { if let state = model.session.researchCase { ResearchCoverageView(model: model, state: state) } }
        .sheet(isPresented:$model.showRequestReview){VStack(alignment:.leading,spacing:12){Text("Review the exact model request").font(.title2);Text("Destination: local Ollama / Model: \(model.pendingModel) / \(model.maskingCount) masking replacements").font(.caption);Text("Context: \(model.pendingContext) tokens / answer ceiling: \(OllamaClient.responseTokenLimit(context:model.pendingContext,inputEstimate:model.pendingPacket?.estimatedTokens ?? 0)) tokens").font(.caption);Text("Original transcript remains local. This frozen preview is what will be sent. Pattern matching cannot find every sensitive value. Image pixels are not redacted by text masking.").font(.caption);HStack{ForEach(model.pendingImages,id:\.self){encoded in if let data=Data(base64Encoded:encoded),let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFit().frame(width:200,height:120)}}};ScrollView{Text(model.requestPreview).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)};HStack{Button("Cancel",action:model.cancelRequestReview);Spacer();Button("Send Reviewed Request",action:model.sendReviewedRequest).buttonStyle(.borderedProminent)}}.padding(22).frame(width:850,height:650)}
        .sheet(isPresented:$model.showProbeReview){VStack(alignment:.leading,spacing:14){Text("Approve one external request").font(.title2);if let request=model.pendingProbe{Text("HEAD \(request.url.absoluteString)").textSelection(.enabled);Text("Via \(request.proxy.description)");Text("\(model.probeMaskCount) masking replacements. This URL, including its query, is the exact transmitted value. The proxy can observe the destination; this is not an anonymity guarantee.");Text("No project files, cookies, authentication headers, or response body. Redirects refused. Failure ends the request; no direct fallback.")};HStack{Button("Cancel",action:model.cancelProxyProbe);Spacer();Button("Allow This Proxy Request",action:model.approveProxyProbe).buttonStyle(.borderedProminent)}}.padding(24).frame(width:700)}
        .sheet(isPresented:$model.showDocumentReview){
            VStack(alignment:.leading,spacing:12){
                Text("Review Document").font(.title2)
                if let candidate=model.pendingDocumentCandidate {Text(candidate.title).font(.headline)}
                Picker("Review",selection:$documentReviewTab){Text("Chapter").tag("Chapter");Text("Code").tag("Code")}.pickerStyle(.segmented)
                ScrollView{Text(documentReviewTab == "Code" ? model.documentCodePreview:model.documentChapterPreview).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                Text("Runs one check in a temporary folder. Network is blocked.").font(.caption)
                DisclosureGroup("Execution details"){
                    Text("Hidden controls are shown as escapes. Project and sibling temporary folders are unreadable; writes stay in scratch. Approval is consumed before execution. A changed chapter or code needs a fresh review. These process restrictions are not a virtual machine.").font(.caption)
                    if let candidate=model.pendingDocumentCandidate {Text("Code SHA-256: "+candidate.codeHash).font(.caption2).textSelection(.enabled)}
                }
                HStack{Button("Cancel"){model.showDocumentReview=false;model.pendingDocumentCandidate=nil};Spacer();Button("Run This Check",action:model.approveDocumentCheck).buttonStyle(.borderedProminent)}
            }.onAppear{documentReviewTab="Chapter"}.padding(22).frame(width:950,height:700)
        }
        .sheet(isPresented:$model.showProposal){VStack(alignment:.leading,spacing:12){Text("Review replacement for \(model.session.file)").font(.headline);Text("This stages the proposed contents. It does not write to disk until you Save. Existing draft is checkpointed.").font(.caption);HSplitView{VStack{Text("CURRENT DRAFT");ScrollView{Text(model.session.draft).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}};VStack{Text("PROPOSED");TextEditor(text:$model.proposal).font(.system(size:11,design:.monospaced))}};HStack{Button("Cancel"){model.showProposal=false};Spacer();Button("Stage in Editor",action:model.applyProposal).disabled(model.session.file.isEmpty)}}.padding(20).frame(width:1000,height:650)}
    }
}
struct EditorTabStrip: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        if !model.editorDocuments.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(model.editorDocuments) { document in
                            HStack(spacing: 8) {
                                Button { model.openFile(document.path) } label: {
                                    HStack(spacing: 6) {
                                        if document.dirty { Circle().fill(acid).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes") }
                                        Text(URL(fileURLWithPath: document.path).lastPathComponent).lineLimit(1)
                                    }
                                }.buttonStyle(.plain).accessibilityLabel("Open " + document.path)
                                Button { model.requestCloseTab(document.path) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).accessibilityLabel("Close " + document.path)
                            }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 9)
                                .background(model.session.file == document.path ? carbon : panel)
                                .overlay(alignment: .bottom) { if model.session.file == document.path { Rectangle().fill(acid).frame(height: 2) } }
                                .help(document.path).id(document.path)
                        }
                    }
                }.onChange(of: model.session.file) { _, path in proxy.scrollTo(path, anchor: .center) }
            }.frame(height: 36).background(panel)
        }
    }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView{
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        let editor=NSTextView();editor.isRichText=false;editor.isAutomaticQuoteSubstitutionEnabled=false;editor.isAutomaticDashSubstitutionEnabled=false;editor.isAutomaticSpellingCorrectionEnabled=false;editor.isContinuousSpellCheckingEnabled=false;editor.font=NSFont.monospacedSystemFont(ofSize:14,weight:.regular);editor.backgroundColor=NSColor(calibratedWhite:0.075,alpha:1);editor.textColor=NSColor(calibratedWhite:0.91,alpha:1);editor.insertionPointColor = .white;editor.textContainerInset=NSSize(width:18,height:18);editor.isHorizontallyResizable=true;editor.isVerticallyResizable=true;editor.autoresizingMask=[.width];editor.textContainer?.widthTracksTextView=false;editor.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);editor.delegate=context.coordinator;editor.allowsUndo=true;scroll.documentView=editor;editor.string=text;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){context.coordinator.parent=self;if let editor=scroll.documentView as? NSTextView,editor.string != text{editor.string=text}}
    final class Coordinator:NSObject,NSTextViewDelegate{var parent:CodeEditor;init(_ parent:CodeEditor){self.parent=parent};func textDidChange(_ notification:Notification){if let editor=notification.object as? NSTextView{parent.text=editor.string}}}
}

struct ScenarioMemoryView: View {
    @ObservedObject var model:WorkbenchModel
    func field(_ key:WritableKeyPath<LabMemory,String>)->Binding<String> {
        Binding(get:{model.session.lab?[keyPath:key] ?? ""},set:{model.session.lab?[keyPath:key]=$0})
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:8) {
                Text("Only this scenario's memory accompanies requests. Save concise facts here; keep detailed artifacts in its folder.").font(.caption2).foregroundStyle(.secondary)
                TextField("Objective",text:field(\.objective))
                TextField("Observed environment / URL / state",text:field(\.environment))
                TextField("Observed markers",text:field(\.markers))
                Text("ATTEMPTS / OBSERVED RESULTS").font(.caption2)
                TextEditor(text:field(\.attempts)).frame(height:80)
                TextField("Evidence paths / timestamps",text:field(\.evidence))
                TextField("Result status / evidence level",text:field(\.result))
                Text("REJECTED TOOLS / REASONS / RETRY CONDITIONS").font(.caption2)
                TextEditor(text:Binding(get:{model.session.lab?.rejectedTools ?? ""},set:{model.session.lab?.rejectedTools=$0})).frame(height:70)
                TextField("Next step",text:field(\.nextStep))
                Button("Load BRIEF + STATE",action:model.loadScenarioNotes)
                Button("Save Scenario Checkpoint",action:model.snapshot)
            }.textFieldStyle(.roundedBorder)
        }.frame(minHeight:240,maxHeight:340)
    }
}
