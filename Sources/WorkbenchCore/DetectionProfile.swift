import Foundation

/// A saved, re-runnable detection test (purple-team). It records exactly what to send — the
/// baseline plus each recorded variation — so the same test can be replayed later or against a
/// different environment and its results compared. The `version` is bumped by the operator when
/// the test *definition* changes, so a later comparison can attribute a difference to the test
/// changing rather than to the defense changing.
public struct DetectionProfile: Codable, Equatable, Sendable {
    public let name: String
    public let method: String
    public let url: String
    public let baseline: RequestVariation
    public let variations: [RequestVariation]
    public let version: Int
    public init(name: String, method: String, url: String, baseline: RequestVariation, variations: [RequestVariation], version: Int = 1) {
        self.name = name; self.method = method; self.url = url
        self.baseline = baseline; self.variations = variations; self.version = version
    }
}

/// One recorded execution of a profile: when, in which operator-labelled environment, at which
/// profile version, the observable reaction per variation, and the host receipts captured.
public struct DetectionRun: Codable, Equatable, Sendable {
    public let profileName: String
    public let profileVersion: Int
    public let environment: String        // operator label: "prod", "staging-eu", …
    public let at: Date
    public let baselineReaction: DefenseReaction
    public let reactions: [String: String]  // variation label -> reaction.rawValue (includes baseline)
    public let evidenceIDs: [String]        // pinned hostReceipts backing this run
    public init(profileName: String, profileVersion: Int, environment: String, at: Date,
                baselineReaction: DefenseReaction, reactions: [String: String], evidenceIDs: [String]) {
        self.profileName = profileName; self.profileVersion = profileVersion; self.environment = environment
        self.at = at; self.baselineReaction = baselineReaction; self.reactions = reactions; self.evidenceIDs = evidenceIDs
    }
}

/// Compares two runs of the SAME profile. A reaction that changed is a LEAD: if the two runs are
/// in the same environment it reads as a detection regression/drift; across environments it reads
/// as an environment difference. A profile-version mismatch is called out, because then a change
/// may be attributable to the test definition rather than to the defense. Promotion still goes
/// through the evidence + FindingVerification path — this only compares recorded reactions.
public enum DetectionComparison {
    public struct Change: Codable, Equatable, Sendable {
        public let label: String   // variation label (or baseline's)
        public let from: String    // prior reaction
        public let to: String      // new reaction
    }
    public struct Result: Codable, Equatable, Sendable {
        public let profileName: String
        public let priorEnvironment: String
        public let newEnvironment: String
        public let priorAt: Date
        public let newAt: Date
        public let sameEnvironment: Bool
        public let versionMatch: Bool
        public let changes: [Change]
        public let detail: String
        public var kind: String { sameEnvironment ? "regression/drift" : "environment-difference" }
        public var hasChanges: Bool { !changes.isEmpty }
    }

    public static func compare(prior: DetectionRun, new: DetectionRun) throws -> Result {
        guard prior.profileName == new.profileName else {
            throw WorkbenchError.invalid("Cannot compare runs of different profiles (\(prior.profileName) vs \(new.profileName)).")
        }
        let labels = Set(prior.reactions.keys).union(new.reactions.keys).sorted()
        var changes: [Change] = []
        for label in labels {
            let a = prior.reactions[label] ?? "absent"
            let b = new.reactions[label] ?? "absent"
            if a != b { changes.append(Change(label: label, from: a, to: b)) }
        }
        let sameEnv = prior.environment == new.environment
        let versionMatch = prior.profileVersion == new.profileVersion
        let kind = sameEnv ? "regression/drift" : "environment-difference"
        let detail: String
        if changes.isEmpty {
            detail = "No reaction changed between the two runs (\(prior.environment) → \(new.environment)). The defense behaved identically to the recorded inputs."
        } else {
            let parts = changes.map { "\($0.label): \($0.from)→\($0.to)" }.joined(separator: ", ")
            var d = "\(changes.count) reaction change(s) [\(kind)]: \(parts). LEAD — verify and capture to promote."
            if !versionMatch { d += " NOTE: the profile version differs (\(prior.profileVersion)→\(new.profileVersion)); some change may be attributable to the test definition, not the defense." }
            detail = d
        }
        return Result(profileName: prior.profileName, priorEnvironment: prior.environment, newEnvironment: new.environment,
                      priorAt: prior.at, newAt: new.at, sameEnvironment: sameEnv, versionMatch: versionMatch,
                      changes: changes, detail: detail)
    }
}

/// Per-engagement store for detection profiles and their run history. One file per engagement
/// (`detection-profiles/<caseID>.json`) keeps profiles — and the runs recorded against them —
/// scoped to that client, consistent with the rest of the per-engagement separation.
public struct DetectionProfileStore {
    public struct StoredProfile: Codable, Equatable, Sendable {
        public var profile: DetectionProfile
        public var runs: [DetectionRun]
        public init(profile: DetectionProfile, runs: [DetectionRun] = []) { self.profile = profile; self.runs = runs }
    }
    public let directory: URL
    public init(root: URL) throws {
        directory = root.appendingPathComponent("detection-profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func file(_ caseID: String) -> URL {
        let safe = caseID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
        return directory.appendingPathComponent(safe + ".json")
    }
    public func load(_ caseID: String) throws -> [StoredProfile] {
        let url = file(caseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 4_194_304 else { throw WorkbenchError.invalid("Detection profile store is too large; inspect it before continuing.") }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([StoredProfile].self, from: data)
    }
    private func save(_ profiles: [StoredProfile], caseID: String) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        let url = file(caseID)
        try enc.encode(profiles).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Record a run: upsert the profile (keeping prior runs) and append this run. Returns the
    /// most recent PRIOR run of the same profile (for comparison), if any.
    @discardableResult
    public func record(profile: DetectionProfile, run: DetectionRun, caseID: String) throws -> DetectionRun? {
        var all = try load(caseID)
        let prior: DetectionRun?
        if let idx = all.firstIndex(where: { $0.profile.name == profile.name }) {
            prior = all[idx].runs.last
            all[idx].profile = profile
            all[idx].runs.append(run)
        } else {
            prior = nil
            all.append(StoredProfile(profile: profile, runs: [run]))
        }
        try save(all, caseID: caseID)
        return prior
    }
}
