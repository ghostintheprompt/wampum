import Foundation

/// Phase 3 bug-bounty output: a program-standard report built ONLY from promoted Findings
/// and their verified host receipts.
///
/// Every candidate claim is re-checked through `FindingVerification` at generation time, so
/// the report cannot contain a claim that is not operator-approved, backed by a host receipt
/// that still verifies byte-for-byte on disk, and clean of the `FindingGate` tells. Claims
/// that do not promote are listed separately as excluded Hypotheses with their blockers — the
/// report never silently drops them, and never upgrades one to look finished.
///
/// What the report does NOT do: it does not assert severity/CVSS, invent a weakness taxonomy,
/// estimate a bounty, or narrate impact as fact. Those are exactly the premature-finding tells
/// the gate blocks, so the template leaves them as operator-filled sections. The machine's
/// contribution is the exact approved claim text plus the hashed, disk-verified evidence.
public enum FindingReport {
    public struct ReceiptRef: Codable, Sendable, Equatable {
        public let id: String
        public let sha256: String
        public let bytes: Int64
        public let file: String   // basename only; the full path stays in the ledger
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let factID: String
        public let title: String
        public let claim: String
        public let meaning: String
        public let receipts: [ReceiptRef]
    }

    public struct Excluded: Codable, Sendable, Equatable {
        public let factID: String
        public let title: String
        public let blockers: [String]
    }

    public struct Report: Codable, Sendable, Equatable {
        public let caseID: String
        public let program: String?
        public let generated: Date
        public let findings: [Entry]
        public let excluded: [Excluded]
        public let markdown: String
    }

    /// Title from the first line of a claim, trimmed to a reasonable length.
    private static func title(_ claim: String) -> String {
        let firstLine = claim.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? claim
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 100 ? String(trimmed.prefix(99)) + "…" : trimmed
    }

    public static func generate(ledger: ResearchEvidence.Ledger, caseID: String, contractHash: String,
                                program: String? = nil, now: Date = Date()) throws -> Report {
        let evidenceIndex = Dictionary(ledger.evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var findings: [Entry] = []
        var excluded: [Excluded] = []

        for fact in ledger.facts {
            let verdict = try FindingVerification.verify(factID: fact.id, ledger: ledger, caseID: caseID, contractHash: contractHash)
            if verdict.isFinding {
                let receipts = verdict.backingEvidenceIDs.compactMap { id -> ReceiptRef? in
                    guard let ev = evidenceIndex[id] else { return nil }
                    return ReceiptRef(id: ev.id, sha256: ev.sha256, bytes: ev.bytes,
                                      file: URL(fileURLWithPath: ev.path).lastPathComponent)
                }
                findings.append(Entry(factID: fact.id, title: title(fact.content), claim: fact.content,
                                      meaning: fact.meaning.rawValue, receipts: receipts))
            } else {
                excluded.append(Excluded(factID: fact.id, title: title(fact.content), blockers: verdict.blockers))
            }
        }

        let markdown = renderMarkdown(caseID: caseID, program: program, now: now, findings: findings, excluded: excluded)
        return Report(caseID: caseID, program: program, generated: now, findings: findings, excluded: excluded, markdown: markdown)
    }

    private static func renderMarkdown(caseID: String, program: String?, now: Date,
                                       findings: [Entry], excluded: [Excluded]) -> String {
        let iso = ISO8601DateFormatter()
        var out = "# Security findings — \(caseID)\n\n"
        if let program, !program.isEmpty { out += "Program: \(program)\n\n" }
        out += "Generated: \(iso.string(from: now))\n\n"
        out += "Every finding below is operator-approved and backed by host-captured evidence that "
        out += "verified byte-for-byte on disk at generation time, and whose claim text passed FindingGate. "
        out += "Severity, weakness classification, reproduction and impact are operator-filled — Wampum does "
        out += "not assert them. Hashes identify the exact evidence; the full paths stay in the case ledger.\n\n"

        if findings.isEmpty {
            out += "## No promoted findings\n\n"
            out += "No claim in this case met the Finding bar (operator-approved + verified host receipt + clean gate). "
            out += "Nothing is reported as a finding.\n\n"
        } else {
            for (i, f) in findings.enumerated() {
                out += "## \(i + 1). \(f.title)\n\n"
                out += "- Status: Finding (operator-approved, \(f.receipts.count) verified host receipt(s))\n"
                out += "- Fact ID: `\(f.factID)` · claim meaning: \(f.meaning)\n"
                out += "- Severity / weakness (CWE) / CVSS: _operator to assess_\n\n"
                // Blockquote the claim so embedded markdown (e.g. a "## " line) can't forge a
                // report section — the claim is operator-reviewed text, not report structure.
                let quoted = f.claim.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                out += "### Approved claim\n\n\(quoted)\n\n"
                out += "### Evidence (captured, hashed, verified on disk)\n\n"
                for r in f.receipts {
                    out += "- `\(r.id)` — `\(r.file)` — sha256 `\(r.sha256)` (\(r.bytes) bytes)\n"
                }
                out += "\n### Reproduction\n\n_operator to document from the evidence above._\n\n"
                out += "### Impact\n\n_operator to state; not asserted by the tool._\n\n---\n\n"
            }
        }

        if !excluded.isEmpty {
            out += "## Excluded (did not meet the Finding bar)\n\n"
            out += "Listed for transparency — not reported to the program. Each is a Hypothesis with its blockers.\n\n"
            for e in excluded {
                out += "- `\(e.factID)` — \(e.title)\n"
                for b in e.blockers { out += "    - \(b)\n" }
            }
            out += "\n"
        }
        return out
    }
}
