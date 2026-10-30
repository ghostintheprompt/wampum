import Foundation

/// A deterministic lint for security claims.
///
/// It flags the tells of a premature "finding" and pushes a claim toward an honest
/// research-note form: observed vs hypothesis kept separate, no severity without
/// demonstrated impact, no invented taxonomy, no self-assigned CVEs, no bounty
/// theatre. It does NOT verify that a claim is true, execute anything, or judge
/// exploitability. Its only job is to stop an unproven claim from being presented
/// as a finding. Semantic truth remains a separate, human step.
public enum FindingGate {
    public enum Level: String, Codable, Sendable { case blocker, warning }

    public struct Issue: Codable, Sendable, Equatable {
        public var rule: String
        public var level: Level
        public var message: String
        public init(rule: String, level: Level, message: String) {
            self.rule = rule; self.level = level; self.message = message
        }
    }

    public struct Verdict: Codable, Sendable {
        public var issues: [Issue]
        public init(issues: [Issue]) { self.issues = issues }
        public var blocked: Bool { issues.contains { $0.level == .blocker } }
        public var summary: String {
            if blocked { return "Not a finding yet. Resolve the blockers and present this as a research note or test plan, not a report." }
            if !issues.isEmpty { return "Reads as a research note. Clean up the warnings before sharing." }
            return "No premature-finding tells detected. This is an honest research note; whether the claim is true is still a separate step."
        }
    }

    /// Words a claim uses about itself to signal it is not yet proven.
    private static let unverifiedMarkers = [
        "unverified", "not been tested", "not tested", "has not been",
        "hypothesis", "requires authorized testing", "deciding unknown",
        "if confirmed", "if the hypothesis", "needs verification", "to be verified", "assumed"
    ]

    public static func review(_ text: String) -> Verdict {
        let lower = text.lowercased()
        var issues: [Issue] = []
        func add(_ rule: String, _ level: Level, _ message: String) {
            issues.append(Issue(rule: rule, level: level, message: message))
        }
        func contains(_ needle: String) -> Bool { lower.contains(needle) }
        func hasAny(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }
        func regex(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }

        let unverified = hasAny(unverifiedMarkers)

        // BLOCKER: a self-assigned or placeholder CVE. CVEs come from CNAs, not the researcher.
        if regex(#"CVE-\d{4}-X{2,}"#) || contains("provisional cve") {
            add("self-assigned-cve", .blocker,
                "Do not self-assign or placeholder a CVE. CVE IDs are issued by CNAs; cite one only if it is already assigned.")
        }

        // BLOCKER: a severity/CVSS rating. Severity is a claim about impact, and impact must be demonstrated.
        let severity = contains("cvss") || contains("severity")
            || contains("**critical**") || contains("why this is critical")
            || regex(#"(?i)\bcritical\b\s*[—:\-]"#)
            || regex(#"(?i)\b(critical|high)\s+(severity|risk|vulnerability)\b"#)
        if severity {
            if unverified {
                add("severity-on-unverified", .blocker,
                    "The claim is marked unverified but still carries a severity. Withhold severity until the deciding unknown is demonstrated with evidence.")
            } else {
                add("severity-without-poc", .blocker,
                    "Severity requires demonstrated, evidenced impact. Show the proof-of-concept that establishes it, or mark the claim unverified and withhold severity.")
            }
        }

        // BLOCKER: framed as a finished report rather than a research note.
        if hasAny(["vulnerability report", "confirmed vulnerability", "this is a finding", "## finding"]) {
            add("premature-report-framing", .blocker,
                "This is framed as a finished vulnerability report. Until the deciding unknown is demonstrated, label it a research note or test plan.")
        }

        // WARNING: the recurring invented technique.
        if contains("flash injection") {
            add("invented-technique", .warning,
                "'Flash injection' is not a recognized technique. Do not present invented taxonomy; name the real class or mark the term as unverified.")
        }

        // WARNING: a vulnerability claim with no recognized taxonomy cited.
        let vulnClaim = hasAny(["vulnerability", "exploit", "injection", "xss", "takeover", "idor", "ssrf", "rce"])
        let taxonomy = regex(#"CWE-\d+"#) || regex(#"(?i)OWASP\s+(A|API|LLM)\d"#)
            || regex(#"A\d{2}:\d{4}"#) || regex(#"(?i)LLM\d{2}"#)
        if vulnClaim && !taxonomy {
            add("no-taxonomy", .warning,
                "No recognized CWE/OWASP class is cited. Map the claim to a primary-source taxonomy ID, or mark the term as unverified.")
        }

        // WARNING: a self-estimated bounty amount.
        if regex(#"\$\s?\d[\d, ]*"#) && hasAny(["bounty", "payout", "hackerone", "bugcrowd"]) {
            add("bounty-estimate", .warning,
                "Remove self-estimated bounty amounts. The program sets severity and payout; estimates read as spam to triagers.")
        }

        // WARNING: unrelated breaches dropped as if they were proof.
        if hasAny(["equifax", "solarwinds", "cambridge analytica"])
            || (hasAny(["linkedin", "facebook"]) && hasAny(["breach", "breaches", "leads to"])) {
            add("breach-namedrop", .warning,
                "Drop references to unrelated breaches. They are not evidence of this bug and weaken the report.")
        }

        // WARNING: impact narrated as fact in a document that never says it observed it.
        if hasAny(["it can:", "the script can", "every action the victim", "you become the victim", "enables:"]) && !contains("observed") {
            add("asserted-impact", .warning,
                "Impact is narrated as if it happened. Keep unproven impact in the Hypothesis section and demonstrate it before claiming it.")
        }

        return Verdict(issues: issues)
    }
}
