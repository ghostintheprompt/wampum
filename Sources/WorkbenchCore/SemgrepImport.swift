import Foundation

/// One Semgrep static-analysis result: a candidate code path, not a finding. Static analysis
/// points at code that *might* be reachable and impactful; the researcher verifies reachability
/// and impact before it can back a Finding. So these import as `sourceReport` leads.
public struct SemgrepFinding: Codable, Equatable, Sendable {
    public let checkID: String
    public let path: String
    public let line: Int
    public let message: String
    public let severity: String
}

/// Parses `semgrep --json` output into candidate code paths. Structure only — it runs nothing
/// and judges nothing; results are leads for the usual reproduce → capture → verify workflow.
public enum SemgrepImport {
    public static func findings(from data: Data) throws -> [SemgrepFinding] {
        guard data.count <= 33_554_432 else { throw WorkbenchError.invalid("Semgrep output exceeds 32 MB; narrow the scan.") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WorkbenchError.invalid("Not valid JSON. Use: semgrep --json")
        }
        guard let results = root["results"] as? [[String: Any]] else {
            throw WorkbenchError.invalid("No results array (is this semgrep --json output?).")
        }
        return results.compactMap { r in
            guard let checkID = r["check_id"] as? String, let path = r["path"] as? String else { return nil }
            let line = (r["start"] as? [String: Any])?["line"] as? Int ?? 0
            let extra = r["extra"] as? [String: Any]
            let message = (extra?["message"] as? String) ?? ""
            let severity = (extra?["severity"] as? String) ?? "INFO"
            return SemgrepFinding(checkID: checkID, path: path, line: line, message: message, severity: severity)
        }
    }
}
