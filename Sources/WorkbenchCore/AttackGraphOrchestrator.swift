import Foundation

/// Closed-loop state for the attack-graph orchestrator: fold the probe `Signal`s from the other
/// AI red-team modules (1–7) into one chained picture of what a target did under test, and
/// suggest the next un-crossed technique for the self-correcting loop to try.
///
/// This is PURE state only — it makes no live calls and launches nothing. It consumes Signals
/// that were already produced + captured elsewhere and summarizes them. Every crossing stays a
/// LEAD, promoted only through the evidence + `FindingVerification` path, never a finding here.
public enum AttackGraphOrchestrator {
    /// One technique's node in the chained graph, built from its probe Signal.
    public struct Node: Codable, Sendable, Equatable {
        public let technique: String
        public let attempted: Bool
        public let crossed: Bool
        public let detail: String
        public init(technique: String, attempted: Bool, crossed: Bool, detail: String) {
            self.technique = technique; self.attempted = attempted; self.crossed = crossed; self.detail = detail
        }
    }

    /// The rolled-up graph across every technique that was probed.
    public struct Report: Codable, Sendable, Equatable {
        public let nodes: [Node]
        public let successfulTechniques: [String]   // techniques whose Signal crossed a boundary
        public let anyCrossing: Bool
        public let detail: String
        public init(nodes: [Node], successfulTechniques: [String], anyCrossing: Bool, detail: String) {
            self.nodes = nodes; self.successfulTechniques = successfulTechniques
            self.anyCrossing = anyCrossing; self.detail = detail
        }
    }

    /// Fold a set of probe Signals into a chained attack graph — one node per technique. A
    /// technique counts as successful when its Signal crossed a boundary; those crossings are the
    /// leads to verify and capture.
    public static func build(from signals: [AIRedTeam.Signal]) -> Report {
        let nodes = signals.map {
            Node(technique: $0.technique, attempted: true, crossed: $0.crossed, detail: $0.detail)
        }
        let successful = nodes.filter(\.crossed).map(\.technique)
        let anyCrossing = !successful.isEmpty

        let detail: String
        if nodes.isEmpty {
            detail = "No probes in the graph; nothing was attempted."
        } else if successful.isEmpty {
            detail = "Chained \(nodes.count) probe(s); no boundary crossing observed on any technique. No lead from this graph."
        } else {
            detail = "Chained \(nodes.count) probe(s); \(successful.count) technique(s) crossed a boundary: \(successful.joined(separator: ", ")). Each crossing is a LEAD — verify against captured evidence and promote through FindingVerification."
        }
        return Report(nodes: nodes, successfulTechniques: successful, anyCrossing: anyCrossing, detail: detail)
    }

    /// The self-correcting loop's next target: the first technique in `allTechniques` that has not
    /// yet crossed in this report, or nil when every listed technique has already crossed.
    public static func nextMutationSuggestion(_ report: Report, allTechniques: [String]) -> String? {
        let crossed = Set(report.successfulTechniques)
        return allTechniques.first { !crossed.contains($0) }
    }
}
