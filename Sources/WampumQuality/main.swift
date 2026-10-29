import Foundation
import WorkbenchCore

@main struct QualityCommand {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 2, args[0] == "--rubric-hash" {
                let rubric = try JSONDecoder().decode(ResearchQuality.Rubric.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                print(try ResearchQuality.rubricHash(rubric)); return
            }
            guard args.count == 10, args[0] == "--rubric", args[2] == "--assessment", args[4] == "--body", args[6] == "--trial", args[8] == "--output" else {
                throw WorkbenchError.invalid("Usage: WampumQuality --rubric FILE --assessment FILE --body MARKDOWN --trial FILE --output NEW_JSON")
            }
            let rubric = try JSONDecoder().decode(ResearchQuality.Rubric.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let assessment = try JSONDecoder().decode(ResearchQuality.Assessment.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let body = try String(contentsOf: URL(fileURLWithPath: args[5]), encoding: .utf8)
            let workspace = try Workspace(root: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
            let policy = try workspace.read(rubric.policyFile)
            let task = try workspace.read(rubric.taskFile)
            let sources = try workspace.read(rubric.sourceManifestFile)
            struct Source: Decodable { let path: String; let bytes: Int64; let sha256: String }
            struct Snapshot: Decodable { let task_sha256: String; let sources: [Source] }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(sources.utf8))
            guard !snapshot.sources.isEmpty, snapshot.task_sha256 == rubric.taskHash, Set(snapshot.sources.map(\.path)).count == snapshot.sources.count else { throw WorkbenchError.invalid("Invalid frozen source snapshot.") }
            for source in snapshot.sources {
                let (hash, bytes) = try IntegrityCheck.hashFile(source.path, limit: 134_217_728)
                guard hash == source.sha256, bytes == source.bytes else { throw WorkbenchError.invalid("Actual source changed: " + source.path) }
            }
            let trial = try String(contentsOf: URL(fileURLWithPath: args[7]), encoding: .utf8)
            let report = try ResearchQuality.evaluate(rubric, assessment: assessment, body: body, policy: policy, task: task, sourceManifest: sources, trialManifest: trial)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try IntegrityCheck.writeNew(data, to: args[9])
            guard try Data(contentsOf: URL(fileURLWithPath: args[9])) == data else { throw WorkbenchError.invalid("Quality report readback mismatch.") }
            print(report.reviewRecordMeetsPolicy ? "REVIEW RECORD MEETS POLICY" : "REVIEW RECORD DOES NOT MEET POLICY")
            // A report is always retained for inspectable incomplete/failed reviews.
            exit(report.reviewRecordMeetsPolicy ? 0 : 2)
        } catch {
            FileHandle.standardError.write(Data("QUALITY REVIEW REFUSED: \(error)\n".utf8)); exit(1)
        }
    }
}
