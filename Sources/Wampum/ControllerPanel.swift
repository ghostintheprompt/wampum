import SwiftUI
import WorkbenchCore

struct ControllerPanel:View {
    @ObservedObject var model:WorkbenchModel
    @ObservedObject var controller:ControllerModel
    var openBrowser:()->Void
    init(model:WorkbenchModel,openBrowser:@escaping ()->Void){self.model=model;self.controller=model.controller;self.openBrowser=openBrowser}
    private func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private var helper:String {
        if Bundle.main.bundleURL.pathExtension=="app" {return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WampumController").path}
        return URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Wampum.app/Contents/MacOS/WampumController").path
    }
    private var launch:String{quote(helper)+" --state-dir "+quote(model.store.directory.path)}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("ENGAGEMENT CONTROLLER").font(.system(size:20,weight:.bold,design:.monospaced));Spacer();Text(controller.enabled ? "ON / SCOPED":"OFF").foregroundStyle(controller.enabled ? .green:.secondary);Button("Open Browser",action:openBrowser)}
            Text("Qwen stays the local default. Codex or Claude Code can use this optional MCP connection. Context and observations returned to a controller may reach its model provider. Wampum does not sign you into either service.").font(.callout)
            HStack {Text("Scenario: "+(model.session.lab?.id ?? "General workspace"));Text(controller.owner).foregroundStyle(.secondary);Spacer();if controller.enabled {Button("Revoke & Stop Browser"){controller.revoke(model:model)}}else{Button("Prepare Handoff"){controller.prepare(model:model)};Button("Enable & Share Reviewed Handoff"){controller.enable(model:model)}.disabled(!controller.prepared)}}
            Text(controller.status).font(.caption).textSelection(.enabled)
            if controller.enabled{Text(controller.remaining).font(.system(size:12,design:.monospaced))}
            HSplitView {
                VStack(alignment:.leading,spacing:8) {
                    Text("EXACT HANDOFF").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$controller.handoff).font(.system(size:12,design:.monospaced)).disabled(controller.enabled)
                    Text("Only this reviewed text is initially shared. Editor contents, chat history, screenshots and other scenarios are excluded automatically. Disable and prepare again to change the handoff.").font(.caption2).foregroundStyle(.secondary)
                    DisclosureGroup("Connect Codex or Claude Code") {
                        Text("Project setup: run python3 scripts/configure-controllers.py after building. Start Codex with python3 scripts/codex-wampum.py. Open Claude Code in this folder and approve its project MCP entry if prompted. Sharing stays off until enabled here. Optional commands below register the helper more widely. Reconnect after a new grant.").font(.caption)
                        Text("Codex").font(.caption.bold());Text("codex mcp add wampum -- "+launch).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                        Text("Claude Code").font(.caption.bold());Text("claude mcp add --transport stdio wampum -- "+launch).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                    }
                }.frame(minWidth:350)
                VStack(alignment:.leading,spacing:10) {
                    if controller.observationTicket != nil {
                        Text("PAGE OBSERVATION / NOT SHARED YET").font(.caption.bold())
                        TextEditor(text:$controller.observationText).font(.system(size:11,design:.monospaced)).frame(minHeight:140)
                        HStack {Button("Deny Observation",action:controller.denyObservation);Button("Share This Observation",action:controller.shareObservation)}
                    }
                    if controller.checkpointTicket != nil {
                        Text("PROPOSED CHECKPOINT / NOT SAVED YET").font(.caption.bold())
                        TextEditor(text:$controller.checkpointText).font(.system(size:11,design:.monospaced)).frame(minHeight:120)
                        HStack {Button("Deny Checkpoint",action:controller.denyCheckpoint);Button("Accept Into Case Notes"){controller.saveCheckpoint(model:model)}}
                    }
                    if model.browser.proposedControllerID != nil {Text("A controller browser action awaits review in Browser. Its exact arguments and the normal Allow/Deny buttons are there.").font(.callout);Button("Review Browser Action",action:openBrowser)}
                    Spacer()
                    Text("One controller per connection. 15-minute expiry, 20 action/checkpoint proposals, 120 calls and 256 KB of returned data. Action results are tool outcomes, never automatic grader-pass claims. The helper has no shell, arbitrary-file, or permission-reset tool.").font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth:350)
            }
        }.padding(18)
    }
}
