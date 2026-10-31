import Foundation

/// Test variation + observability (purple-team / detection-validation).
///
/// The question this answers is NOT "how do I get past the defense" — it is "did the defense
/// observably react differently to these controlled, fully-recorded variations of the same
/// request?" That measures detection/attribution coverage, which is legitimate engagement work.
///
/// Hard design constraints (from the operator roadmap):
///   - This is NOT a stealth / evasion / obfuscation mode. A variation is a *test input*; the
///     exact variation is preserved so a reviewer can see precisely what was sent.
///   - Wampum observes only the externally visible defense reaction (the HTTP response and any
///     marker the capture layer saw). It does NOT claim to read the defense's internal
///     telemetry; if the operator has the defense's own logs/alerts, those are pinned as
///     separate evidence.
///   - Every result is a LEAD. A detection-differential is promoted to a finding only through
///     the existing evidence + `FindingVerification` workflow, never on this signal alone.
///   - The engagement RoE (authorized scope) is the boundary; the sender is scope-gated.

/// One controlled variation of a base request. Everything it changes is explicit and recorded.
public struct RequestVariation: Codable, Equatable, Sendable {
    public let label: String                    // "baseline", "ua-rotated", "spaced-timing", "param-url-encoded"
    public let headerOverrides: [String: String] // headers this variation sets/changes, verbatim
    public let delayMs: Int                     // deliberate timing change, in ms (0 = none)
    public let note: String                     // what this varies and why — for the reviewer
    public init(label: String, headerOverrides: [String: String] = [:], delayMs: Int = 0, note: String = "") {
        self.label = label; self.headerOverrides = headerOverrides; self.delayMs = delayMs; self.note = note
    }
}

/// The externally observable reaction of a defense to one request. Inferred only from the
/// response status and any marker the capture layer flagged — never from guessed intent.
public enum DefenseReaction: String, Codable, Sendable {
    case allowed, blocked, rateLimited, challenged, authRequired, serverError, other
}

/// One observed response for a variation. Body is carried as a hash; markers are observable
/// signals the capture layer saw in the response (e.g. a captcha page, a WAF block page).
public struct VariationObservation: Codable, Equatable, Sendable {
    public let label: String
    public let status: Int
    public let bodySHA256: String
    public let bodyBytes: Int
    public let markers: [String]
    public init(label: String, status: Int, bodySHA256: String, bodyBytes: Int, markers: [String] = []) {
        self.label = label; self.status = status; self.bodySHA256 = bodySHA256; self.bodyBytes = bodyBytes; self.markers = markers
    }
    public var reaction: DefenseReaction { TestVariationAnalysis.reaction(status: status, markers: markers) }
}

public enum TestVariationAnalysis {
    /// Classify the observable reaction. Markers take priority over status (a 200 that serves a
    /// captcha page is a challenge, not an allow).
    public static func reaction(status: Int, markers: [String]) -> DefenseReaction {
        let m = Set(markers.map { $0.lowercased() })
        if m.contains("captcha") || m.contains("challenge") || m.contains("js-challenge") { return .challenged }
        if m.contains("waf-block") || m.contains("blockpage") || m.contains("blocked") { return .blocked }
        switch status {
        case 429: return .rateLimited
        case 403, 406: return .blocked
        case 401: return .authRequired
        case 200..<300: return .allowed
        case 500..<600: return .serverError
        default: return .other
        }
    }

    public struct Signal: Codable, Equatable, Sendable {
        public let baselineLabel: String
        public let baselineReaction: DefenseReaction
        public let reactions: [String: String]       // label -> reaction.rawValue (includes baseline)
        public let differingVariations: [String]      // variation labels whose reaction != baseline
        public let detail: String
        /// True when at least one variation drew a different observable reaction than baseline —
        /// i.e. the defense distinguishes the inputs. A lead, not a finding.
        public var detectionObserved: Bool { !differingVariations.isEmpty }
    }

    /// Compare each variation's observable reaction to the baseline's. A differential is a LEAD:
    /// it means the defense treated the recorded variation differently — detection/attribution
    /// signal to verify and capture, not a finding on its own.
    public static func evaluate(baseline: VariationObservation, variations: [VariationObservation]) throws -> Signal {
        let allLabels = [baseline.label] + variations.map(\.label)
        guard Set(allLabels).count == allLabels.count else {
            throw WorkbenchError.invalid("Variation labels (including baseline) must be unique.")
        }
        var reactions: [String: String] = [baseline.label: baseline.reaction.rawValue]
        var differing: [String] = []
        for v in variations {
            reactions[v.label] = v.reaction.rawValue
            if v.reaction != baseline.reaction { differing.append(v.label) }
        }
        let detail: String
        if differing.isEmpty {
            detail = "Every variation drew the same observable reaction as baseline (\(baseline.reaction.rawValue)). No detection-differential; the defense did not distinguish these recorded inputs (as observed from responses only)."
        } else {
            let parts = differing.map { "\($0)→\(reactions[$0] ?? "?")" }.joined(separator: ", ")
            detail = "Baseline reacted \(baseline.reaction.rawValue); these variations drew a different observable reaction: \(parts). Detection-differential LEAD — the defense distinguishes the recorded inputs. Verify against the defense's own telemetry and capture to promote. This is observed response behavior, not proof of the defense's internal detection."
        }
        return Signal(baselineLabel: baseline.label, baselineReaction: baseline.reaction,
                      reactions: reactions, differingVariations: differing, detail: detail)
    }
}
