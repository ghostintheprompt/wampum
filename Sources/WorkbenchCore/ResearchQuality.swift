import Foundation

/// Validates evidence-linked review records. It does not execute programs,
/// authenticate reviewers, or independently establish that cited evidence is true.
public enum ResearchQuality {
    public struct Criterion: Codable, Sendable { public var id: String; public var requirement: String }
    public struct Dimension: Codable, Sendable {
        public var id: String
        public var name: String
        public var weight: Double
        public var criteria: [Criterion]
    }
    public struct Rubric: Codable, Sendable {
        public var id: String
        public var version: String
        public var sourceManifestHash: String
        public var policyHash: String
        public var taskHash: String
        public var policyFile: String
        public var taskFile: String
        public var sourceManifestFile: String
        public var criticalMinimums: [String: Int]
        public var passThreshold: Double
        public var dimensionFloor: Double
        public var dimensions: [Dimension]
        public var gates: [Criterion]
        public var requiredUnits: [Criterion]
    }
    public enum Status: String, Codable, Sendable { case pass, fail, notEvaluated }
    public struct Rating: Codable, Sendable {
        public var criterionID: String
        public var score: Int?
        public var evidence: [String]
    }
    public struct Check: Codable, Sendable {
        public var id: String
        public var status: Status
        public var evidence: [String]
    }
    public struct Evidence: Codable, Sendable {
        public var id: String
        public var kind: String
        public var path: String
        public var sha256: String
        public var artifactHash: String
    }
    public struct Trial: Codable, Sendable {
        public var id: String
        public var caseID: String
        public var condition: String
        public var authorArm: String
        public var state: String
        public var configuration: [String: JSONValue]
        public var assistance: [String]
    }
    public struct Assessment: Codable, Sendable {
        public var rubricID: String
        public var rubricVersion: String
        public var rubricHash: String
        public var sourceManifestHash: String
        public var artifactHash: String
        public var trialManifestHash: String
        public var reviewer: String
        public var evidenceIndex: [Evidence]
        public var ratings: [Rating]
        public var gates: [Check]
        public var units: [Check]
    }
    public struct Report: Codable, Sendable {
        public var rubricID: String
        public var rubricVersion: String
        public var rubricHash: String
        public var artifactHash: String
        public var sourceManifestHash: String
        public var trialManifestHash: String
        public var trialID: String
        public var condition: String
        public var authorArm: String
        public var trialState: String
        public var reviewer: String
        public var score: Double?
        public var lowerBound: Double
        public var upperBound: Double
        public var assessedWeight: Double
        public var dimensionScores: [String: Double]
        public var unratedCriteria: [String]
        public var failedGates: [String]
        public var unverifiedGates: [String]
        public var unmetUnits: [String]
        public var belowFloor: [String]
        public var criticalFailures: [String]
        public var failedUnits: [String]
        public var unverifiedUnits: [String]
        public var dimensionBounds: [String: [Double]]
        public var reviewRecordMeetsPolicy: Bool
        public var limitation: String
    }

    public static func rubricHash(_ rubric: Rubric) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ResearchDocument.digest(String(decoding: try encoder.encode(rubric), as: UTF8.self))
    }

    public static func evaluate(_ rubric: Rubric, assessment: Assessment, body: String, policy: String, task: String, sourceManifest: String, trialManifest: String) throws -> Report {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw WorkbenchError.invalid(message) }
        }
        func hasText(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func isHash(_ text: String) -> Bool {
            text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
        }
        func validateDefinitions(_ items: [Criterion]) throws {
            try require(!items.isEmpty && Set(items.map(\.id)).count == items.count, "Empty or duplicate rubric definitions.")
            try require(items.allSatisfy { hasText($0.id) && hasText($0.requirement) }, "Blank rubric definition.")
        }
        try require(hasText(rubric.id) && hasText(rubric.version), "Rubric identity is missing.")
        try require(isHash(rubric.sourceManifestHash), "Invalid source manifest hash.")
        try require(rubric.policyHash == ResearchDocument.digest(policy) && rubric.taskHash == ResearchDocument.digest(task) && rubric.sourceManifestHash == ResearchDocument.digest(sourceManifest), "Task, policy or source snapshot changed.")
        try require(assessment.trialManifestHash == ResearchDocument.digest(trialManifest), "Trial conditions or assistance changed.")
        let trial = try JSONDecoder().decode(Trial.self, from: Data(trialManifest.utf8))
        try require(trial.caseID == rubric.id && hasText(trial.id) && hasText(trial.condition) && ["chatgpt", "wampum", "fixture"].contains(trial.authorArm) && ["completed", "failed", "blocked", "notRun"].contains(trial.state), "Invalid trial identity or state.")
        if trial.state == "completed", trial.authorArm != "fixture" {
            let required = ["model", "runtime", "tools", "contextTokens", "outputTokens", "temperature", "thinking", "auditSeed", "auditRule", "pairedTrialID", "plannedTrials", "attemptID", "retryBudget", "assistanceMode"]
            try require(required.allSatisfy { trial.configuration[$0] != nil }, "Completed comparison is missing effective trial conditions; use explicit unknown values where necessary.")
            for field in ["auditRule", "pairedTrialID", "attemptID", "assistanceMode"] {
                try require(trial.configuration[field]?.string.map(hasText) == true, "Trial review/attempt protocol must be explicit: " + field)
            }
            func integer(_ field: String, minimum: Double, unknownAllowed: Bool) -> Bool {
                switch trial.configuration[field] {
                case .number(let value): return value.isFinite && value >= minimum && value.rounded(.towardZero) == value
                case .null: return unknownAllowed
                default: return false
                }
            }
            for field in ["contextTokens", "outputTokens"] {
                try require(integer(field, minimum: 1, unknownAllowed: true), "Invalid budget: " + field)
            }
            try require(integer("plannedTrials", minimum: 1, unknownAllowed: false) && integer("retryBudget", minimum: 0, unknownAllowed: false) && integer("auditSeed", minimum: 0, unknownAllowed: false), "Trial count/retry/audit seed must be explicit nonnegative integers; trial count must be positive.")
            for field in ["model", "runtime"] {
                switch trial.configuration[field] {
                case .string(let value): try require(hasText(value), "Blank trial identity: " + field)
                case .null: break
                default: throw WorkbenchError.invalid("Invalid trial identity: " + field)
                }
            }
            switch trial.configuration["tools"] {
            case .array(let tools): try require(tools.allSatisfy { $0.string.map(hasText) == true }, "Tool names must be nonblank strings.")
            case .null: break
            default: throw WorkbenchError.invalid("Tools must be an array or explicitly unknown.")
            }
            switch trial.configuration["temperature"] {
            case .number(let value): try require(value.isFinite && value >= 0, "Invalid temperature.")
            case .null: break
            default: throw WorkbenchError.invalid("Temperature must be numeric or explicitly unknown.")
            }
            switch trial.configuration["thinking"] {
            case .bool, .null: break
            default: throw WorkbenchError.invalid("Thinking must be boolean or explicitly unknown.")
            }
        }
        if trial.authorArm == "wampum" {
            try require(trial.configuration["model"]?.string == "lukey03/Qwen3.5-9B-abliterated:latest", "Wampum trial must retain the approved installed model.")
        }
        try require(rubric.passThreshold.isFinite && (0...100).contains(rubric.passThreshold), "Invalid pass threshold.")
        try require(rubric.dimensionFloor.isFinite && (0...100).contains(rubric.dimensionFloor), "Invalid dimension floor.")
        try require(!rubric.dimensions.isEmpty && Set(rubric.dimensions.map(\.id)).count == rubric.dimensions.count, "Duplicate or missing dimensions.")
        for dimension in rubric.dimensions {
            try require(hasText(dimension.id) && hasText(dimension.name) && dimension.weight.isFinite && dimension.weight > 0, "Invalid dimension.")
            try validateDefinitions(dimension.criteria)
        }
        try require(abs(rubric.dimensions.reduce(0) { $0 + $1.weight } - 100) < 0.000001, "Dimension weights must total 100.")
        let criteria = rubric.dimensions.flatMap(\.criteria)
        try validateDefinitions(criteria)
        try validateDefinitions(rubric.gates)
        try validateDefinitions(rubric.requiredUnits)
        try require(assessment.rubricID == rubric.id && assessment.rubricVersion == rubric.version && assessment.sourceManifestHash == rubric.sourceManifestHash, "Assessment rubric/source binding changed.")
        try require(assessment.rubricHash == rubricHash(rubric), "Rubric content changed; fresh review required.")
        try require(isHash(assessment.artifactHash) && assessment.artifactHash == ResearchDocument.digest(body), "Assessment does not match the exact document bytes.")
        try require(hasText(assessment.reviewer), "Reviewer attribution required.")
        let allowed = Set(criteria.map(\.id))
        try require(rubric.criticalMinimums.allSatisfy { allowed.contains($0.key) && (1...4).contains($0.value) }, "Invalid critical minimum.")
        try require(Set(assessment.evidenceIndex.map(\.id)).count == assessment.evidenceIndex.count, "Duplicate evidence ID.")
        let evidence = Dictionary(uniqueKeysWithValues: assessment.evidenceIndex.map { ($0.id, $0) })
        for item in assessment.evidenceIndex {
            try require(hasText(item.id) && hasText(item.kind) && item.artifactHash == assessment.artifactHash && isHash(item.sha256), "Invalid or stale evidence binding.")
            let (hash, _) = try IntegrityCheck.hashFile(item.path, limit: 134_217_728)
            try require(hash == item.sha256, "Evidence file changed: " + item.id)
        }
        func validateReferences(_ ids: [String]) throws {
            try require(!ids.isEmpty && ids.allSatisfy { evidence[$0] != nil }, "Evidence IDs must resolve to current pinned files.")
        }
        try require(Set(assessment.ratings.map(\.criterionID)).count == assessment.ratings.count, "Duplicate criterion rating.")
        for rating in assessment.ratings {
            try require(allowed.contains(rating.criterionID), "Unknown criterion rating.")
            if let score = rating.score {
                try require((0...4).contains(score), "Ratings must be integers from 0 to 4.")
                try validateReferences(rating.evidence)
            }
        }
        func validateChecks(_ checks: [Check], definitions: [Criterion]) throws -> [String: Check] {
            let ids = Set(definitions.map(\.id))
            try require(Set(checks.map(\.id)).count == checks.count, "Duplicate check.")
            for check in checks {
                try require(ids.contains(check.id), "Unknown check.")
                if check.status != .notEvaluated {
                    try validateReferences(check.evidence)
                }
            }
            return Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        }
        let gates = try validateChecks(assessment.gates, definitions: rubric.gates)
        let units = try validateChecks(assessment.units, definitions: rubric.requiredUnits)
        if let gate = gates["code"], gate.status == .pass {
            let kinds = Set(gate.evidence.compactMap { evidence[$0]?.kind })
            try require(Set(["code", "test", "execution"]).isSubset(of: kinds), "Code gate requires code, test and execution evidence.")
        }
        if let gate = gates["save"], gate.status == .pass {
            try require(gate.evidence.contains { evidence[$0]?.kind == "save" && evidence[$0]?.sha256 == assessment.artifactHash }, "Save gate requires exact artifact readback evidence.")
        }
        let ratings = Dictionary(uniqueKeysWithValues: assessment.ratings.map { ($0.criterionID, $0) })
        var lower = 0.0, upper = 0.0, assessed = 0.0
        var dimensionScores: [String: Double] = [:], dimensionBounds: [String: [Double]] = [:], unrated: [String] = []
        for dimension in rubric.dimensions {
            let points = dimension.criteria.compactMap { ratings[$0.id]?.score }
            let count = Double(dimension.criteria.count)
            let known = Double(points.reduce(0, +)) / (4 * count)
            lower += dimension.weight * known
            upper += dimension.weight * (known + Double(dimension.criteria.count - points.count) / count)
            assessed += dimension.weight * Double(points.count) / count
            dimensionBounds[dimension.id] = [known * 100, (known + Double(dimension.criteria.count - points.count) / count) * 100]
            if points.count == dimension.criteria.count { dimensionScores[dimension.id] = known * 100 }
            unrated += dimension.criteria.filter { ratings[$0.id]?.score == nil }.map(\.id)
        }
        let failed = rubric.gates.filter { gates[$0.id]?.status == .fail }.map(\.id)
        let unverified = rubric.gates.filter { gates[$0.id] == nil || gates[$0.id]?.status == .notEvaluated }.map(\.id)
        let unmet = rubric.requiredUnits.filter { units[$0.id]?.status != .pass }.map(\.id)
        let below = rubric.dimensions.filter { (dimensionBounds[$0.id]?[1] ?? 100) < rubric.dimensionFloor }.map(\.id)
        let critical = rubric.criticalMinimums.keys.sorted().filter { id in if let score = ratings[id]?.score { return score < rubric.criticalMinimums[id]! }; return false }
        let score = unrated.isEmpty ? lower : nil
        let passes = score.map { $0 >= rubric.passThreshold } == true && failed.isEmpty && unverified.isEmpty && unmet.isEmpty && below.isEmpty && critical.isEmpty && trial.state == "completed"
        return Report(rubricID: rubric.id, rubricVersion: rubric.version, rubricHash: try rubricHash(rubric), artifactHash: assessment.artifactHash, sourceManifestHash: rubric.sourceManifestHash, trialManifestHash: assessment.trialManifestHash, trialID: trial.id, condition: trial.condition, authorArm: trial.authorArm, trialState: trial.state, reviewer: assessment.reviewer, score: score, lowerBound: lower, upperBound: upper, assessedWeight: assessed, dimensionScores: dimensionScores, unratedCriteria: unrated, failedGates: failed, unverifiedGates: unverified, unmetUnits: unmet, belowFloor: below, criticalFailures: critical, failedUnits: rubric.requiredUnits.filter { units[$0.id]?.status == .fail }.map(\.id), unverifiedUnits: rubric.requiredUnits.filter { units[$0.id] == nil || units[$0.id]?.status == .notEvaluated }.map(\.id), dimensionBounds: dimensionBounds, reviewRecordMeetsPolicy: passes, limitation: "Validates supplied evidence-linked review records and pinned files only. Does not verify evidence truth, execute code, authenticate the reviewer or certify an isolated oracle. Native operator-reviewed export may enforce this report alongside fresh case, source, journal and review checks; the report alone never authorizes release.")
    }
}
