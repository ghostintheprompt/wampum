import Foundation
import AppKit
import WorkbenchCore

@MainActor final class IntegrityModel:ObservableObject {
    @Published var baselinePath=""
    @Published var baseline:IntegritySnapshot?
    @Published var report:IntegrityReport?
    @Published var busy=false
    @Published var message="Choose a baseline to review its coverage. Checking never replaces it."
    @Published var error:String?
    @Published var showingCreation=false
    @Published var modelRoot:String
    @Published var manifestPath=""
    @Published var contextRoots:[String]
    let directory:URL
    private var baselineBytes:Data?
    private var task:Task<Void,Never>?
    init(directory:URL,initialBaseline:URL?=nil) {
        self.directory=directory.appendingPathComponent("integrity")
        modelRoot=ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models").path
        contextRoots=[directory.path]
        if let initialBaseline {load(initialBaseline)}
    }
    var availableBaselines:[URL] {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}
    }
    func chooseBaseline() {
        guard !busy else{return}
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false;panel.allowedContentTypes=[.json];panel.directoryURL=directory
        if panel.runModal() == .OK,let url=panel.url{load(url)}
    }
    func load(_ url:URL) {
        guard !busy else{return}
        baseline=nil;baselineBytes=nil;report=nil;error=nil;baselinePath=url.path
        do {
            let bytes=try IntegrityCheck.boundedData(url.path,limit:2*1024*1024)
            let value=try JSONDecoder().decode(IntegritySnapshot.self,from:bytes)
            guard value.schemaVersion=="wampum-integrity/v1",value.complete,Set(value.entries.map(\.path)).count==value.entries.count else{throw WorkbenchError.invalid("Baseline is incomplete, unsupported or has duplicate paths.")}
            baseline=value;baselineBytes=bytes;message="Coverage loaded. Review the paths, then run the comparison."
        }catch{self.error=error.localizedDescription;message="Baseline could not be loaded. Existing file preserved."}
    }
    func check() {
        guard !busy,let saved=baseline,let bytes=baselineBytes else{return}
        let path=baselinePath;report=nil;error=nil;busy=true;message="Hashing selected model and context files locally…"
        let worker=Task.detached(priority:.utility) {
            guard try IntegrityCheck.boundedData(path,limit:2*1024*1024)==bytes else{throw WorkbenchError.invalid("Baseline changed since review. Choose it again before checking.")}
            let current=try IntegrityCheck.snapshot(saved.recipe)
            try Task.checkCancellation()
            guard try IntegrityCheck.boundedData(path,limit:2*1024*1024)==bytes else{throw WorkbenchError.invalid("Baseline changed during comparison. No report accepted.")}
            return try IntegrityCheck.compare(baseline:saved,current:current,baselineBytes:bytes)
        }
        task=Task {
            defer{busy=false;task=nil}
            do {
                let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation();report=value
                message=value.status=="unchanged" ? "No byte changes detected in the selected coverage." : value.status=="incomplete" ? "Inspection incomplete. Review unreadable or invalid evidence." : "Changes detected. Review each path before deciding what it means."
            }catch is CancellationError{message="Comparison cancelled. Baseline preserved."}catch{self.error=error.localizedDescription;message="Comparison failed. Baseline preserved."}
        }
    }
    func cancel(){guard busy else{return};task?.cancel();message="Stopping after the current read…"}
    func chooseManifest() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.directoryURL=URL(fileURLWithPath:modelRoot).appendingPathComponent("manifests")
        if panel.runModal() == .OK,let url=panel.url{manifestPath=url.path}
    }
    func chooseModelStore(){let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;if panel.runModal() == .OK,let url=panel.url{modelRoot=url.path}}
    func addContext(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=true;if panel.runModal() == .OK{for url in panel.urls where !contextRoots.contains(url.path){contextRoots.append(url.path)}}}
    func createBaseline() {
        guard !busy,!manifestPath.isEmpty else{return}
        let destination=directory.appendingPathComponent("\(UUID().uuidString)-baseline.json")
        let recipe=IntegrityRecipe(modelRoot:modelRoot,manifest:manifestPath,contextRoots:contextRoots,excludedPaths:[directory.path])
        error=nil;report=nil;busy=true;showingCreation=false;message="Reading files for a new first-observation baseline…"
        let worker=Task.detached(priority:.utility) {
            let snapshot=try IntegrityCheck.snapshot(recipe)
            try Task.checkCancellation()
            guard snapshot.complete else{throw WorkbenchError.invalid("No baseline saved. Inspection incomplete:\n"+snapshot.issues.joined(separator:"\n"))}
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let data=try encoder.encode(snapshot)
            guard data.count<=2*1024*1024 else{throw WorkbenchError.invalid("Baseline exceeds 2 MB.")}
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try Task.checkCancellation()
            try IntegrityCheck.writeNew(data,to:destination.path)
            return destination
        }
        task=Task {
            do {
                let url=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                busy=false;task=nil;load(url)
                message=Task.isCancelled ? "New baseline saved before cancellation completed. Older baselines preserved." : "New first-observation baseline saved. Older baselines preserved."
            }catch{busy=false;task=nil;if error is CancellationError{message="Baseline creation cancelled before save."}else{self.error=error.localizedDescription;message="Baseline not created. Existing baselines preserved."}}
        }
    }
    func exportReport(to url:URL)throws {
        guard let report,let baseline else{throw WorkbenchError.invalid("Run a comparison before exporting.")}
        let output=url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !baseline.recipe.contextRoots.contains(where:{let root=URL(fileURLWithPath:$0).resolvingSymlinksInPath().standardizedFileURL.path;return output==root || output.hasPrefix(root+"/")}) else{throw WorkbenchError.invalid("Choose a report location outside monitored context roots.")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try IntegrityCheck.writeNew(encoder.encode(report),to:url.path)
    }
    func saveReport(){let panel=NSSavePanel();panel.nameFieldStringValue="wampum-integrity-\(UUID().uuidString).json";panel.allowedContentTypes=[.json];if panel.runModal() == .OK,let url=panel.url{do{try exportReport(to:url);message="Private report saved. Baseline unchanged."}catch{self.error=error.localizedDescription}}}
}
