import SwiftUI
import WorkbenchCore

struct IntegrityPanel:View {
    @ObservedObject var model:IntegrityModel
    private let accent=Color(red:0.76,green:0.83,blue:0.57)
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5){Text("INTEGRITY").font(.system(size:22,weight:.bold,design:.rounded));Text("Model files and saved context / local comparison").foregroundStyle(.secondary)}
                Spacer()
                Button("Choose Baseline…",action:model.chooseBaseline).disabled(model.busy)
                Button("New Baseline…"){model.showingCreation=true}.disabled(model.busy)
                Button("Run Comparison",action:model.check).disabled(model.busy || model.baseline==nil).buttonStyle(.borderedProminent)
                if model.busy{Button("Cancel",action:model.cancel)}
            }
            Text("Unchanged bytes do not prove a safe model. This checks the selected files against a first observation, not their training history or intent.").font(.callout).foregroundStyle(.secondary)
            if !model.availableBaselines.isEmpty {
                HStack{Text("Saved here").font(.caption);Menu("Choose a saved baseline"){ForEach(model.availableBaselines,id:\.path){url in Button(url.lastPathComponent){model.load(url)}}}.disabled(model.busy)}
            }
            if !model.baselinePath.isEmpty{Text(model.baselinePath).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}
            HStack{if model.busy{ProgressView().controlSize(.small)};Text(model.message).foregroundStyle(accent);Spacer();if model.report != nil{Button("Save Report…",action:model.saveReport).disabled(model.busy)}}
            if let error=model.error{Text(error).foregroundStyle(.red).textSelection(.enabled)}
            HSplitView {
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        Text("SELECTED COVERAGE").font(.headline).foregroundStyle(accent)
                        if let baseline=model.baseline {
                            Text("\(baseline.entries.count) recorded files / \(baseline.created.formatted())").font(.caption)
                            path("Model store",baseline.recipe.modelRoot);path("Manifest",baseline.recipe.manifest)
                            ForEach(baseline.recipe.contextRoots,id:\.self){path("Context root",$0)}
                            ForEach(baseline.recipe.excludedPaths,id:\.self){path("Excluded",$0)}
                            Text("Directory scans cover nonhidden md, json, jsonl, txt, toml, yaml and yml files. Explicit file roots cover that file. Other files and live model memory are outside coverage.").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Recorded files"){ForEach(baseline.entries,id:\.path){entry in VStack(alignment:.leading){Text(entry.kind).font(.caption).foregroundStyle(accent);Text(entry.path).font(.system(size:11,design:.monospaced));Text(entry.sha256).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}.padding(.vertical,4).textSelection(.enabled)}}
                        }else{Text("Choose a baseline to inspect its paths. Nothing is scanned automatically.").foregroundStyle(.secondary)}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                }.frame(minWidth:300,idealWidth:400)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        Text("COMPARISON").font(.headline).foregroundStyle(accent)
                        if let report=model.report {
                            Text(report.status.uppercased()).font(.system(size:18,weight:.bold,design:.monospaced))
                            Text("\(report.inspectedFiles) files read / \(report.changes.count) changes / \(report.issues.count) issues").font(.callout)
                            Text(report.checked.formatted()).font(.caption).foregroundStyle(.secondary)
                            if report.changes.isEmpty && report.complete{Text("No differences found in this comparison. Earlier activity and unselected files are not attested.")}
                            ForEach(report.changes,id:\.path){change in VStack(alignment:.leading,spacing:5){Text(change.change).foregroundStyle(accent);Text(change.path).font(.system(size:11,design:.monospaced));Text("Before: "+(change.previousSHA256 ?? "not recorded"));Text("Now: "+(change.currentSHA256 ?? "not available"))}.font(.system(size:10,design:.monospaced)).textSelection(.enabled).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.04))}
                            ForEach(Array(report.issues.enumerated()),id:\.offset){_,issue in Text(issue).foregroundStyle(.orange).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}
                            DisclosureGroup("Assurance limits and baseline hash"){Text(report.assurance).font(.caption);Text(report.baselineSHA256).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}
                        }else{Text("A comparison will list changed paths and incomplete evidence here. Legitimate edits can produce changes.").foregroundStyle(.secondary)}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                }.frame(minWidth:400)
            }
        }.padding(20)
        .sheet(isPresented:$model.showingCreation){creation}
    }
    private func path(_ label:String,_ value:String)->some View{VStack(alignment:.leading,spacing:3){Text(label).font(.caption).foregroundStyle(accent);Text(value).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
    private var creation:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Create a separate baseline").font(.title2)
            Text("This records the files as they are now. It does not certify them as clean. Earlier baselines stay on disk.").foregroundStyle(.secondary)
            HStack{path("Ollama model store",model.modelRoot);Spacer();Button("Choose Store…",action:model.chooseModelStore)}
            HStack{path("Exact model manifest",model.manifestPath.isEmpty ? "Not selected":model.manifestPath);Spacer();Button("Choose Manifest…",action:model.chooseManifest)}
            HStack{Text("Context files and folders").font(.headline);Spacer();Button("Add…",action:model.addContext)}
            ScrollView{ForEach(model.contextRoots,id:\.self){root in HStack{Text(root).font(.system(size:11,design:.monospaced)).textSelection(.enabled);Spacer();Button("Remove"){model.contextRoots.removeAll{$0==root}}}}}.frame(minHeight:80,maxHeight:150)
            Text("Directory coverage: nonhidden md/json/jsonl/txt/toml/yaml/yml only. The baseline folder is excluded. No note bodies are saved in the baseline. Hashes and paths remain local.").font(.caption).foregroundStyle(.secondary)
            path("Save a new file inside",model.directory.path)
            HStack{Button("Cancel"){model.showingCreation=false};Spacer();Button("Record Current Files",action:model.createBaseline).disabled(model.manifestPath.isEmpty).buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:780)
    }
}
