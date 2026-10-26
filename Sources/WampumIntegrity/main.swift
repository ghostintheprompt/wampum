import Foundation
import CryptoKit
import WorkbenchCore

func run() throws -> Int32 {
    let args=Array(CommandLine.arguments.dropFirst())
    guard let operation=args.first,["baseline","check"].contains(operation) else{throw WorkbenchError.invalid("Usage: WampumIntegrity baseline --models STORE --manifest FILE [--context PATH ...] --baseline NEW_FILE | check --baseline FILE [--report NEW_FILE]")}
    var values:[String:String]=[:],contexts:[String]=[]
    var index=1
    while index<args.count {
        let key=args[index]
        guard ["--models","--manifest","--context","--baseline","--report"].contains(key),index+1<args.count,!args[index+1].hasPrefix("--") else{throw WorkbenchError.invalid("Invalid or incomplete option.")}
        if key=="--context"{contexts.append(URL(fileURLWithPath:args[index+1]).standardizedFileURL.path)}else{guard values[key]==nil else{throw WorkbenchError.invalid("Duplicate option: \(key)")};values[key]=args[index+1]}
        index+=2
    }
    guard let baseline=values["--baseline"] else{throw WorkbenchError.invalid("--baseline is required.")}
    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    if operation=="baseline" {
        guard let models=values["--models"],let manifest=values["--manifest"],values["--report"]==nil else{throw WorkbenchError.invalid("Baseline requires --models and --manifest; --report is for check.")}
        let recipe=IntegrityRecipe(modelRoot:URL(fileURLWithPath:models).standardizedFileURL.path,manifest:URL(fileURLWithPath:manifest).standardizedFileURL.path,contextRoots:contexts,excludedPaths:[URL(fileURLWithPath:baseline).standardizedFileURL.path])
        let snapshot=try IntegrityCheck.snapshot(recipe)
        guard snapshot.complete else{throw WorkbenchError.invalid("Incomplete inspection; baseline was not created:\n"+snapshot.issues.joined(separator:"\n"))}
        let data=try encoder.encode(snapshot)
        guard data.count<=2*1024*1024 else{throw WorkbenchError.invalid("Baseline exceeds 2 MB.")}
        try IntegrityCheck.writeNew(data,to:baseline)
        print("Baseline SHA-256: \(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())")
        print("Baseline saved: \(snapshot.entries.count) files. First observation only; not a clean-model attestation.")
    }else{
        guard values["--models"]==nil,values["--manifest"]==nil,contexts.isEmpty else{throw WorkbenchError.invalid("Check uses the saved recipe; create a separate baseline to change coverage.")}
        let bytes=try IntegrityCheck.boundedData(baseline,limit:2*1024*1024)
        let saved=try JSONDecoder().decode(IntegritySnapshot.self,from:bytes)
        let current=try IntegrityCheck.snapshot(saved.recipe)
        let report=try IntegrityCheck.compare(baseline:saved,current:current,baselineBytes:bytes)
        if let output=values["--report"] {
            let canonicalOutput=URL(fileURLWithPath:output).standardizedFileURL.resolvingSymlinksInPath().path
            guard !saved.recipe.contextRoots.contains(where:{root in canonicalOutput==root || canonicalOutput.hasPrefix(root+"/")}) else{throw WorkbenchError.invalid("Write the report outside monitored context roots to avoid changing the evidence.")}
            try IntegrityCheck.writeNew(try encoder.encode(report),to:output)
        }
        print("\(report.status): \(report.inspectedFiles) files, \(report.changes.count) changes, \(report.issues.count) issues. Unchanged does not mean clean.")
        if !report.complete || !report.changes.isEmpty{return 2}
    }
    return 0
}
do{exit(try run())}catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
