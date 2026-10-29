import Foundation

/// Local consistency and explicit operator signoff, not authenticated proof or semantic certification.
public enum ResearchRelease {
    public struct Paths: Codable, Equatable, Sendable {
        public let rubric: String
        public let assessment: String
        public let trial: String
        public init(rubric: String, assessment: String, trial: String) {
            self.rubric = rubric; self.assessment = assessment; self.trial = trial
        }
    }
    public struct Pin: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int64
    }
    public struct Evaluation: Codable, Sendable {
        public let paths: Paths
        public let pins: [Pin]
        public let journalPins: [Pin]
        public let coverage: [ResearchSourceCoverage]
        public let report: ResearchQuality.Report
        public let assessment: ResearchQuality.Assessment
        public let trial: ResearchQuality.Trial
        public func includingJournals(_ pins: [Pin]) -> Evaluation {
            Evaluation(paths: paths, pins: self.pins, journalPins: pins, coverage: coverage, report: report, assessment: assessment, trial: trial)
        }
        public var fixtureOnly: Bool { trial.authorArm == "fixture" }
        public func digest() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return ResearchSectionWorkflow.hash(try encoder.encode(self))
        }
    }
    public struct GapReview: Codable, Sendable {
        public let sourcePath: String
        public let originalHash: String
        public let extractedHash: String
        public let evidenceID: String
        public let findings: String
        public init(source: ResearchSourceCapture, evidenceID: String, findings: String) {
            sourcePath = source.original.canonicalPath; originalHash = source.original.sha256
            extractedHash = source.extractedTextSHA256; self.evidenceID = evidenceID; self.findings = findings
        }
    }
    public struct Approval: Codable, Sendable {
        public let evaluation: Evaluation
        public let evaluationHash: String
        public let workflowHash: String
        public let reviewer: String
        public let findings: String
        public let gapReviews: [GapReview]
        public let date: Date
        public init(evaluation: Evaluation, workflowHash: String, reviewer: String, findings: String, gapReviews: [GapReview]) throws {
            guard evaluation.report.reviewRecordMeetsPolicy else { throw WorkbenchError.invalid("The recomputed review record does not meet policy.") }
            guard reviewer.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                  findings.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
                throw WorkbenchError.invalid("Explicit reviewer attribution and substantive whole-document findings are required.")
            }
            self.evaluation = evaluation; evaluationHash = try evaluation.digest(); self.workflowHash = workflowHash
            self.reviewer = reviewer; self.findings = findings; self.gapReviews = gapReviews; date = Date()
        }
    }
    private struct Source: Decodable { let path: String; let bytes: Int64; let sha256: String }
    private struct Snapshot: Decodable { let task_sha256: String; let sources: [Source] }

    /// Bounded reads bind the decoded data to the exact bytes hashed before and after reading.
    public static func read(_ path: String, limit: Int64 = 4_194_304) throws -> (Data, Pin) {
        guard path.hasPrefix("/"), limit >= 0, limit < Int64(Int.max) else { throw WorkbenchError.invalid("Absolute bounded quality file required.") }
        let first = try IntegrityCheck.hashFile(path, limit: limit)
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let handle = try FileHandle(forReadingFrom: canonical); defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(limit) + 1) ?? Data()
        let last = try IntegrityCheck.hashFile(path, limit: limit)
        guard first.0 == last.0, first.1 == last.1, Int64(data.count) == last.1,
              ResearchSectionWorkflow.hash(data) == last.0 else { throw WorkbenchError.invalid("Quality input changed while reading.") }
        return (data, Pin(path: canonical.path, sha256: last.0, bytes: last.1))
    }
    public static func validatePins(_ pins: [Pin]) throws {
        for pin in pins {
            let (hash, bytes) = try IntegrityCheck.hashFile(pin.path, limit: pin.bytes)
            guard hash == pin.sha256, bytes == pin.bytes else { throw WorkbenchError.invalid("Quality input or evidence changed: " + pin.path) }
        }
    }
    public static func evaluate(paths: Paths, state: ResearchCaseState, body: Data) throws -> Evaluation {
        guard let plan = state.sourcePlan else { throw WorkbenchError.invalid("Exact source allocation is required for native release.") }
        let coverage = try plan.coverage(contract: state.contract, captures: state.sources)
        guard let text = String(data: body, encoding: .utf8) else { throw WorkbenchError.invalid("Release document must be exact UTF-8 Markdown.") }
        var pins: [Pin] = []
        func load(_ path: String) throws -> Data { let (data, pin) = try read(path); pins.append(pin); return data }
        func string(_ data: Data) throws -> String {
            guard let value = String(data: data, encoding: .utf8) else { throw WorkbenchError.invalid("Quality inputs must be UTF-8.") }; return value
        }
        let rubricData = try load(paths.rubric)
        let rubric = try JSONDecoder().decode(ResearchQuality.Rubric.self, from: rubricData)
        guard rubric.id == state.contract.id, try ResearchQuality.rubricHash(rubric) == state.contract.rubricSHA256,
              rubric.requiredUnits.map(\.id) == state.contract.requiredUnits else {
            throw WorkbenchError.invalid("Rubric differs from the case's frozen identity, hash or ordered required units.")
        }
        let assessment = try JSONDecoder().decode(ResearchQuality.Assessment.self, from: load(paths.assessment))
        let trialData = try load(paths.trial)
        let trial = try JSONDecoder().decode(ResearchQuality.Trial.self, from: trialData)
        guard ["wampum", "fixture"].contains(trial.authorArm) else { throw WorkbenchError.invalid("Native section release requires a Wampum or explicitly labeled fixture trial.") }
        let workspace = try Workspace(root: URL(fileURLWithPath: paths.rubric).deletingLastPathComponent())
        let policy = try string(load(workspace.resolve(rubric.policyFile).path))
        let task = try string(load(workspace.resolve(rubric.taskFile).path))
        let sourceText = try string(load(workspace.resolve(rubric.sourceManifestFile).path))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(sourceText.utf8))
        guard !snapshot.sources.isEmpty, snapshot.task_sha256 == rubric.taskHash,
              Set(snapshot.sources.map(\.path)).count == snapshot.sources.count else { throw WorkbenchError.invalid("Invalid source inventory.") }
        var actual: [String: Pin] = [:]; var total: Int64 = 0
        for source in snapshot.sources {
            guard source.path.hasPrefix("/"), source.bytes >= 0, source.bytes <= 134_217_728 else { throw WorkbenchError.invalid("Invalid source size.") }
            let (hash, bytes) = try IntegrityCheck.hashFile(source.path, limit: source.bytes)
            let path = URL(fileURLWithPath: source.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard hash == source.sha256, bytes == source.bytes, actual[path] == nil else { throw WorkbenchError.invalid("Changed or duplicate actual source: " + source.path) }
            total += bytes; guard total <= 536_870_912 else { throw WorkbenchError.invalid("Source verification exceeds its 512 MB allocation; no files were omitted.") }
            let pin = Pin(path: path, sha256: hash, bytes: bytes); actual[path] = pin; pins.append(pin)
        }
        let capturedPaths = state.sources.map { URL(fileURLWithPath: $0.original.canonicalPath).resolvingSymlinksInPath().standardizedFileURL.path }
        guard Set(capturedPaths).count == state.sources.count, Set(capturedPaths) == Set(actual.keys),
              zip(state.sources, capturedPaths).allSatisfy({ source, path in
                  actual[path]?.sha256 == source.original.sha256 && actual[path]?.bytes == Int64(source.original.byteCount)
              }) else {
            throw WorkbenchError.invalid("Native captured sources do not match the complete rubric source inventory.")
        }
        guard assessment.evidenceIndex.count <= 4096 else { throw WorkbenchError.invalid("Too many quality evidence files.") }
        var evidenceBytes: Int64 = 0
        for item in assessment.evidenceIndex {
            guard item.path.hasPrefix("/") else { throw WorkbenchError.invalid("Quality evidence paths must be absolute.") }
            let (hash, bytes) = try IntegrityCheck.hashFile(item.path, limit: 134_217_728)
            evidenceBytes += bytes; guard evidenceBytes <= 268_435_456 else { throw WorkbenchError.invalid("Evidence verification exceeds 256 MB; no evidence was omitted.") }
            guard hash == item.sha256 else { throw WorkbenchError.invalid("Quality evidence changed: " + item.id) }
            pins.append(Pin(path: URL(fileURLWithPath: item.path).resolvingSymlinksInPath().standardizedFileURL.path, sha256: hash, bytes: bytes))
        }
        let report = try ResearchQuality.evaluate(rubric, assessment: assessment, body: text, policy: policy, task: task, sourceManifest: sourceText, trialManifest: string(trialData))
        let grouped = Dictionary(grouping: pins, by: \.path)
        guard grouped.values.allSatisfy({ Set($0.map(\.sha256)).count == 1 }) else { throw WorkbenchError.invalid("Input changed between its uses.") }
        let unique = grouped.keys.sorted().compactMap { grouped[$0]?.first }
        try validatePins(unique)
        return Evaluation(paths: paths, pins: unique, journalPins: [], coverage: coverage, report: report, assessment: assessment, trial: trial)
    }
    public static func validateCoverage(state: ResearchCaseState, evaluation: Evaluation, reviews: [GapReview]) throws {
        guard let plan = state.sourcePlan else { throw WorkbenchError.invalid("Exact source allocation required.") }
        let coverage = try plan.coverage(contract: state.contract, captures: state.sources)
        guard coverage.allSatisfy({ $0.omittedWindowIndices.isEmpty }) else { throw WorkbenchError.invalid("Some extracted source windows have never been allocated to a required section.") }
        let gaps = state.sources.filter { !$0.fullDocumentTextCoverage || $0.extractedText.isEmpty || !$0.warnings.isEmpty }
        guard Set(reviews.map(\.sourcePath)).count == reviews.count,
              Set(reviews.map(\.sourcePath)) == Set(gaps.map { $0.original.canonicalPath }) else {
            throw WorkbenchError.invalid("Every source with visual/extraction uncertainty needs its own explicit review.")
        }
        for gap in gaps {
            guard let review = reviews.first(where: { $0.sourcePath == gap.original.canonicalPath }),
                  review.originalHash == gap.original.sha256, review.extractedHash == gap.extractedTextSHA256,
                  review.findings.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32,
                  evaluation.assessment.evidenceIndex.contains(where: { $0.id == review.evidenceID && $0.kind == "source-review" }) else {
                throw WorkbenchError.invalid("Source-gap review requires exact source bindings, findings and source-review evidence in the assessment.")
            }
        }
    }
    /// Checks supplied execution-record consistency. It cannot authenticate a receipt or rerun a test.
    public static func validateExecutionRecords(_ evaluation: Evaluation, body: Data) throws {
        guard let gate = evaluation.assessment.gates.first(where: { $0.id == "code" && $0.status == .pass }) else { return }
        let evidence = evaluation.assessment.evidenceIndex.filter { gate.evidence.contains($0.id) }
        let runs = evidence.filter { $0.kind == "execution" }
        let blocks = closedCodeHashes(String(decoding: body, as: UTF8.self))
        guard evidence.filter({ $0.kind == "code" }).allSatisfy({ blocks.contains($0.sha256) }) else {
            throw WorkbenchError.invalid("Indexed code does not match an exact closed code block in the reviewed document.")
        }
        var subjects: Set<String> = []; var oracles: Set<String> = []
        for run in runs {
            let (data, _) = try read(run.path, limit: 4_194_304)
            let record: JSONValue
            if let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = json { record = json }
            else {
                let records = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("VERIFIED_RECEIPT ") }
                guard records.count == 1, let line = records.first else { throw WorkbenchError.invalid("Execution evidence needs one unambiguous host receipt.") }
                record = try JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst("VERIFIED_RECEIPT ".count).utf8))
            }
            func integer(_ key: String, minimum: Double) -> Bool {
                guard case .number(let value) = record[key] else { return false }
                return value.isFinite && value.rounded(.towardZero) == value && value >= minimum
            }
            guard record["oracleIsolation"]?.string == "sandbox-exec-worker",
                  (evaluation.fixtureOnly || record["fixture"]?.isTrue != true),
                  record["independentOracle"]?.isTrue == true, record["passed"]?.isTrue == true,
                  integer("tests", minimum: 3), integer("calls", minimum: 1),
                  record["failures"] == .number(0), record["errors"] == .number(0), record["skipped"] == .number(0),
                  evidence.contains(where: { $0.kind == "code" && $0.sha256 == record["subjectSHA256"]?.string }),
                  evidence.contains(where: { $0.kind == "test" && $0.sha256 == record["oracleSHA256"]?.string }) else {
                throw WorkbenchError.invalid("Code release requires a current isolated host receipt bound to the cited code and tests; shared-process or inconsistent records cannot pass.")
            }
            if let hash = record["subjectSHA256"]?.string { subjects.insert(hash) }
            if let hash = record["oracleSHA256"]?.string { oracles.insert(hash) }
        }
        guard evidence.filter({ $0.kind == "code" }).allSatisfy({ subjects.contains($0.sha256) }),
              evidence.filter({ $0.kind == "test" }).allSatisfy({ oracles.contains($0.sha256) }) else {
            throw WorkbenchError.invalid("Some indexed code or oracle files lack matching isolated execution records.")
        }
    }
    private static func closedCodeHashes(_ body: String) -> Set<String> {
        var marker: Character?; var length = 0; var content = ""; var hashes: Set<String> = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let active = marker {
                if line.count >= length && line.allSatisfy({ $0 == active }) {
                    hashes.insert(ResearchSectionWorkflow.hash(Data(content.utf8))); marker = nil; content = ""
                } else { content += raw + "\n" }
            } else if let first = line.first, first == "`" || first == "~" {
                let count = line.prefix(while: { $0 == first }).count
                if count >= 3 { marker = first; length = count; content = "" }
            }
        }
        return hashes
    }
    public static func validateSectionJournals(_ evaluation: Evaluation, workflow: ResearchSectionWorkflow, state: ResearchCaseState) throws -> [Pin] {
        if evaluation.fixtureOnly { return [] }
        guard evaluation.trial.state == "completed", evaluation.trial.authorArm == "wampum",
              evaluation.trial.configuration["model"]?.string == "lukey03/Qwen3.5-9B-abliterated:latest" else {
            throw WorkbenchError.invalid("Native model release needs a completed trial for the approved installed model.")
        }
        var pins: [Pin] = []
        for unit in workflow.requiredSectionIDs {
            guard let attempt = workflow.attempts.last(where: { $0.sectionID == unit }),
                  attempt.provenance.model == evaluation.trial.configuration["model"]?.string else {
                throw WorkbenchError.invalid("Trial model differs from a required section's provenance.")
            }
            let root = URL(fileURLWithPath: attempt.provenance.requestID)
            let (requestData, requestPin) = try read(root.appendingPathComponent("request.json").path)
            let request = try JSONDecoder().decode(JSONValue.self, from: requestData)
            let (bindingData, bindingPin) = try read(root.appendingPathComponent("section-request.json").path)
            let binding = try JSONDecoder().decode(ResearchSectionRequest.self, from: bindingData)
            let (responseData, responsePin) = try read(root.appendingPathComponent("response.json").path)
            let response = try JSONDecoder().decode(ChatReply.self, from: responseData)
            let (terminalData, terminalPin) = try read(root.appendingPathComponent("terminal.json").path)
            let terminal = try JSONDecoder().decode(JSONValue.self, from: terminalData)
            var selected = state; selected.activeSourceUnit = unit
            guard attempt.provenance.requestSHA256 == requestPin.sha256,
                  attempt.provenance.responseSHA256 == responsePin.sha256,
                  attempt.provenance.bindingSHA256 == bindingPin.sha256,
                  request["messages"]?.array?.isEmpty == false,
                  request["model"]?.string == attempt.provenance.model,
                  request["researchFingerprint"]?.string == (try selected.requestFingerprint()),
                  request["context"] == evaluation.trial.configuration["contextTokens"],
                  binding.caseID == attempt.caseID, binding.contractHash == attempt.contractHash, binding.unitID == unit,
                  Set(binding.sources) == Set(attempt.sources),
                  response.message.content == attempt.body, response.done_reason == attempt.stopReason,
                  response.eval_count == attempt.outputTokens, response.prompt_eval_count == attempt.inputTokens,
                  terminal["state"]?.string == "responseSaved" else {
                throw WorkbenchError.invalid("A section's actual request/raw response/terminal record no longer matches its trial and accepted attempt.")
            }
            pins += [requestPin, bindingPin, responsePin, terminalPin]
        }
        return pins
    }

}
