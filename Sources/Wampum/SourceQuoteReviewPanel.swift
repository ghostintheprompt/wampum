import SwiftUI
import WorkbenchCore

struct SourceQuoteReviewPanel: View {
    let review: SourceQuoteReview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE QUOTE CHECK — NOT A FACT CHECK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Text(review.summary).font(.caption)
            Text(review.limitation).font(.caption2).foregroundStyle(.secondary)
            if !review.findings.isEmpty {
                DisclosureGroup("Review quoted spans") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(statusLabel(finding.status))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(finding.status == .exactMatch ? .green : .orange)
                                Text(finding.text).font(.caption).textSelection(.enabled)
                                if let citation = finding.citedSource {
                                    Text("Cited: \(citation)").font(.caption2).foregroundStyle(.secondary)
                                }
                                if !finding.matchedSources.isEmpty {
                                    Text("Text found in: \(finding.matchedSources.joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statusLabel(_ status: SourceQuoteStatus) -> String {
        switch status {
        case .exactMatch: "EXACT TEXT MATCH"
        case .notFound: "QUOTE NOT FOUND IN ATTACHED DRAFTS"
        case .citationMissing: "QUOTE FOUND, SOURCE NOT CITED"
        case .citationNotAttached: "CITED SOURCE NOT ATTACHED"
        case .sourceMismatch: "QUOTE FOUND IN A DIFFERENT ATTACHED SOURCE"
        }
    }
}
