import SwiftUI
import AppKit
import WorkbenchCore

struct BrowserPanel:View {
    @ObservedObject var model:WorkbenchModel
    @ObservedObject var browser:BrowserModel
    var onOpenChat:(()->Void)?
    @State private var inspector="Actions"
    @State private var showReset=false
    init(model:WorkbenchModel,onOpenChat:(()->Void)?=nil){self.model=model;self.browser=model.browser;self.onOpenChat=onOpenChat}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("PLAYWRIGHT / CONTROLLED PAGE").font(.system(size:12,weight:.bold,design:.monospaced))
                Spacer()
                Text(browser.connected ? "CONNECTED":"DISCONNECTED").font(.caption).foregroundStyle(browser.connected ? .green:.secondary)
                if browser.busy || browser.capturing {ProgressView().controlSize(.small);Button("Stop",action:browser.stop)}
            }
            HStack {
                Text(model.session.lab?.id ?? "GENERAL").font(.caption).foregroundStyle(.secondary)
                Picker("Model",selection:$model.session.model){Text("Choose installed model").tag("");ForEach(model.models){m in Text(m.name).tag(m.name)}}.labelsHidden().frame(maxWidth:480)
                Button("Discover",action:model.discover).disabled(browser.busy)
                Text(model.capabilities.joined(separator:" / ")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                TextField("Page URL",text:$browser.address).textFieldStyle(.roundedBorder)
                Button("Go",action:browser.navigate).disabled(!browser.connected || browser.busy || browser.capturing)
                Button("Browser Check",action:browser.loadSelfCheck).disabled(!browser.connected || browser.busy || browser.capturing)
                if browser.connected {Button("Disconnect",action:browser.disconnect)}
                else {Button("Connect"){browser.requestConnect(scenario:model.session.lab?.id)}.disabled(browser.busy || browser.disconnecting)}
            }
            if !browser.connected {
                Toggle("Local browser connections only",isOn:$browser.localOnly).disabled(browser.busy)
                Toggle("Also show a separate Chrome window",isOn:$browser.showChromeWindow).disabled(browser.busy)
                Text("Uses a separate Chrome session. External mode can contact websites and their third parties. Your existing Chrome tabs and profile are not attached. Browser requests do not inherit the proxy or content masking settings.").font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Connection setup / troubleshooting") {
                    TextField("Node executable",text:$browser.nodePath).textFieldStyle(.roundedBorder)
                    TextField("Installed @playwright/mcp/cli.js",text:$browser.serverPath).textFieldStyle(.roundedBorder)
                    Button("Detect Installed Server",action:browser.detect)
                    Text("Uses installed packages only. No automatic download, sign-in, or browser extension required.").font(.caption2)
                }
            }
            Text(browser.status).font(.caption).textSelection(.enabled)
            if let receipt=browser.receipts.last {Text("LAST RECEIPT: "+receipt.summary).font(.caption2).textSelection(.enabled)}
            HSplitView {
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text("CONTROLLED TAB / VIEW-ONLY CAPTURE").font(.caption2)
                        Spacer()
                        Toggle("Live",isOn:$browser.livePreview).toggleStyle(.checkbox).font(.caption).disabled(!browser.connected)
                        Button("Refresh Page State",action:browser.refresh).disabled(!browser.connected || browser.busy || browser.capturing)
                        Button("Use Capture in Chat"){if model.attachBrowserCapture(){onOpenChat?()}}.disabled(browser.screenshot==nil || browser.busy || browser.capturing)
                    }
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.4)
                            if let data=browser.screenshot,let image=NSImage(data:data) {Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width,height:geometry.size.height)}
                            else {Text("The actual Playwright-controlled page appears here after Go.\nQwen reads its accessibility snapshot; it does not need vision to use browser tools.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()}
                        }
                    }.frame(minHeight:200)
                    if let time=browser.capturedAt {Text("Last capture: "+time.formatted(date:.omitted,time:.standard)+". Updates after actions or every three seconds when Live is on.").font(.caption2).foregroundStyle(.secondary)}
                }.frame(minWidth:300)
                VStack(alignment:.leading,spacing:8) {
                    Picker("Inspect",selection:$inspector){Text("Actions").tag("Actions");Text("Page").tag("Page");Text("Debug").tag("Debug")}.pickerStyle(.segmented)
                    if inspector=="Actions" {
                        TextField("Browser objective",text:$browser.goal).textFieldStyle(.roundedBorder)
                        Button("Review Context → Ask Qwen"){browser.preparePlan(model:model)}.disabled(!browser.connected || browser.busy || browser.capturing || browser.proposed != nil)
                        Text("Qwen proposes. You approve one exact action.").font(.caption2).foregroundStyle(.secondary)
                        if let call=browser.proposed {
                            Text(call.name).font(.system(size:12,weight:.bold,design:.monospaced))
                            ScrollView {Text(call.arguments.pretty).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}.frame(maxHeight:140)
                            HStack {Button("Deny"){browser.denyProposal(model:model)};Button("Allow This Action"){browser.approveProposal(model:model)}.disabled(browser.busy || browser.capturing)}
                            Text("One use. This page snapshot, goal and scope only.").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !browser.explanation.isEmpty {ScrollView{Text(browser.explanation).font(.caption).textSelection(.enabled)}.frame(maxHeight:100)}
                        ScrollView {Text(browser.events.joined(separator:"\n")).font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                    } else if inspector=="Page" {
                        ScrollView {Text(browser.snapshot).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                    } else {
                        Text("Connection errors, rejected calls, and console output appear here. A failure stops automatic capture retries. Local browser logs may contain page text and entered values.").font(.caption2)
                        Button("Show Local Logs",action:browser.revealLogs)
                        Button("Read Browser Console",action:browser.inspectConsole).disabled(!browser.connected || browser.busy || browser.capturing)
                        Button("Retry Conditions Changed…"){showReset=true}.disabled(browser.busy || browser.capturing)
                        ScrollView {Text(browser.diagnostics.isEmpty ? "No diagnostics recorded.":browser.diagnostics).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}
                    }
                }.frame(minWidth:220,idealWidth:280,maxWidth:380)
            }
        }.padding(12)
        .onAppear {browser.goal=model.session.browserGoal ?? "";if let url=model.session.browserURL{browser.address=url}}
        .onChange(of:browser.goal){_,value in model.session.browserGoal=value;model.persist()}
        .onChange(of:browser.address){_,value in model.session.browserURL=value;model.persist()}
        .task {while !Task.isCancelled {do{try await Task.sleep(nanoseconds:3_000_000_000)}catch{return};if browser.connected && browser.livePreview && !browser.busy && !browser.capturing && browser.capturedAt != nil {await browser.capture()}}}
        .confirmationDialog("Allow external browser connections?",isPresented:$browser.showExternalWarning,titleVisibility:.visible){Button("Allow for This Browser Connection",action:browser.connect);Button("Cancel",role:.cancel){browser.showExternalWarning=false}}message:{Text("This isolated Chrome session can connect to websites, redirects and third parties. It uses your ordinary network connection and is not covered by Wampum's proxy tool. Disconnect ends this browser connection.")}
        .confirmationDialog("Reset rejected browser requests?",isPresented:$showReset,titleVisibility:.visible){Button("Conditions Have Changed",action:browser.resetRejections);Button("Cancel",role:.cancel){}}message:{Text("Reset only after correcting the underlying issue or granting the needed permission. Otherwise the same failed request will repeat. The activity log is preserved.")}
        .sheet(isPresented:$browser.showPlanReview){VStack(alignment:.leading,spacing:12){Text("Review browser context for local Qwen").font(.title2);Text("This request proposes an action. It does not execute a browser tool.").font(.caption);ScrollView{Text(browser.planPreview).font(.system(size:11,design:.monospaced)).textSelection(.enabled)};HStack{Button("Cancel",action:browser.cancelPlan);Spacer();Button("Ask Qwen"){browser.sendPlan(model:model)}}}.padding(22).frame(width:850,height:650)}
    }
}
struct ImageAttachmentTray:View {
    @ObservedObject var model:WorkbenchModel
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack{Button("Add Images…",action:model.addImages).disabled(model.busy || model.showRequestReview);if !(model.session.images ?? []).isEmpty {Button("Extract Text",action:model.extractImageText);Button("Remove"){model.session.images=[];model.persist()}}}
            if !(model.session.images ?? []).isEmpty {
                HStack{ForEach(model.session.images ?? [],id:\.self){path in if let data=try? ImageAttachments.data(path,directory:model.imageDirectory),let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFit().frame(width:100,height:70)}}}
                Text(model.capabilities.contains("vision") ? "Image pixels will be sent to the local model after review. Text masking does not redact pixels.":"Selected model has no reported vision. Extract Text uses on-device OCR, or select an installed vision model.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
