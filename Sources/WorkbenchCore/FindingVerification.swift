import Foundation

/// Phase 2 bug-bounty verification loop.
///
/// A security claim starts as a Hypothesis. It becomes a Finding only when, at the moment
/// of checking, ALL of the following hold:
///   1. its fact is operator-APPROVED in the evidence ledger (the ledger already bars
///      model-proposal evidence from approved memory, so model confidence cannot get here),
///   2. it references at least one `hostReceipt` evidence item that still verifies
///      byte-for-byte on disk (captured, hashed evidence — not narration), and
///   3. its text passes `FindingGate` with no blockers.
///
/// Anything short of all three leaves the claim a Hypothesis with explicit blockers.
/// Nothing here executes code, judges exploitability, or authenticates a reviewer; it only
/// decides whether the evidence and review state justify calling a claim a Finding. It is
/// fail-closed: an unknown fact, a disk change, a missing receipt or a gate blocker all keep
/// the claim a Hypothesis.
public enum FindingVerification {
    public enum Status: String, Codable, Sendable { case hypothesis, finding }

    public struct Verdict: Codable, Sendable, Equatable {
        public let status: Status
        public let factID: String
        public let claimHash: String
        /// hostReceipt evidence IDs that backed the claim and verified on disk right now.
        public let backingEvidenceIDs: [String]
        public let gateIssues: [FindingGate.Issue]
        /// Why the claim is still a Hypothesis. Empty exactly when status == .finding.
        public let blockers: [String]
        public init(status: Status, factID: String, claimHash: String, backingEvidenceIDs: [String], gateIssues: [FindingGate.Issue], blockers: [String]) {
            self.status = status; self.factID = factID; self.claimHash = claimHash
            self.backingEvidenceIDs = backingEvidenceIDs; self.gateIssues = gateIssues; self.blockers = blockers
        }
        public var isFinding: Bool { status == .finding }
        public var summary: String {
            if isFinding {
                return "Finding: approved claim backed by \(backingEvidenceIDs.count) verified host receipt(s), clean of premature-finding tells. Program triage is still a separate step."
            }
            return "Hypothesis — not promoted. " + blockers.joined(separator: " ")
        }
    }

    public static func verify(factID: String, ledger: ResearchEvidence.Ledger, caseID: String, contractHash: String) throws -> Verdict {
        guard let fact = ledger.facts.first(where: { $0.id == factID }) else {
            throw ResearchEvidence.Failure.invalid("Unknown claim fact: \(factID)")
        }
        var blockers: [String] = []

        // (3) FindingGate re-check on the exact claim text.
        let gate = FindingGate.review(fact.content)
        for issue in gate.issues where issue.level == .blocker {
            blockers.append("FindingGate: \(issue.message)")
        }

        // (1) Operator-approved state. Validates the whole ledger binding; model proposals
        // can never reach .approved, so an approved fact already excludes model confidence.
        let state = try ledger.state(of: factID)
        if state != .approved {
            blockers.append("The claim is not operator-approved (state: \(state.rawValue)). An approved review backed by host evidence is required.")
        }

        // (2) Captured, hashed host evidence that still verifies on disk right now.
        let index = Dictionary(ledger.evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let referenced = fact.evidenceIDs.compactMap { index[$0] }
        let hostReceipts = referenced.filter { $0.kind == .hostReceipt }
        if hostReceipts.isEmpty {
            blockers.append("No host-captured evidence backs this claim. A verified host receipt (captured browser/check evidence) is required; model assertion alone cannot promote it.")
        }
        var verified: [String] = []
        for item in hostReceipts {
            do {
                let (digest, bytes) = try IntegrityCheck.hashFile(item.path, limit: item.bytes)
                if digest == item.sha256 && bytes == item.bytes {
                    verified.append(item.id)
                } else {
                    blockers.append("Host receipt \(item.id) changed on disk since it was pinned; it no longer backs the claim.")
                }
            } catch {
                blockers.append("Host receipt \(item.id) is missing or unreadable; it no longer backs the claim.")
            }
        }
        if !hostReceipts.isEmpty && verified.isEmpty && !blockers.contains(where: { $0.contains("changed on disk") || $0.contains("missing or unreadable") }) {
            blockers.append("No referenced host receipt verified on disk.")
        }

        let status: Status = blockers.isEmpty ? .finding : .hypothesis
        return Verdict(status: status, factID: factID, claimHash: fact.contentHash,
                       backingEvidenceIDs: verified, gateIssues: gate.issues, blockers: blockers)
    }
}
