import Foundation

public enum SourceQuoteStatus: String, Codable, Sendable {
    case exactMatch
    case notFound
    case citationMissing
    case citationNotAttached
    case sourceMismatch
}

public struct SourceQuoteFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let citedSource: String?
    public let matchedSources: [String]
    public let status: SourceQuoteStatus

    public init(id: Int, text: String, citedSource: String?, matchedSources: [String], status: SourceQuoteStatus) {
        self.id = id
        self.text = text
        self.citedSource = citedSource
        self.matchedSources = matchedSources
        self.status = status
    }
}

/// Checks only whether Markdown blockquote text appears verbatim in the exact
/// editor drafts supplied to one source-review request. It does not verify claims.
public struct SourceQuoteReview: Codable, Equatable, Sendable {
    public let findings: [SourceQuoteFinding]

    public init(answer: String, sources: [String: String]) {
        let quotedSpans = Self.extractBlockQuotes(answer)
        findings = quotedSpans.enumerated().map { index, span in
            let matches = sources
                .filter { Self.normalized($0.value).contains(Self.normalized(span.text)) }
                .map(\.key)
                .sorted()

            guard let citation = span.citation else {
                return SourceQuoteFinding(id: index, text: span.text, citedSource: nil,
                    matchedSources: matches, status: matches.isEmpty ? .notFound : .citationMissing)
            }

            guard let source = sources.keys.first(where: { Self.citation(citation, names: $0) }) else {
                return SourceQuoteFinding(id: index, text: span.text, citedSource: citation,
                    matchedSources: matches, status: .citationNotAttached)
            }

            if matches.contains(source) {
                return SourceQuoteFinding(id: index, text: span.text, citedSource: citation,
                    matchedSources: matches, status: .exactMatch)
            }
            return SourceQuoteFinding(id: index, text: span.text, citedSource: citation,
                matchedSources: matches, status: matches.isEmpty ? .notFound : .sourceMismatch)
        }
    }

    public var summary: String {
        guard !findings.isEmpty else {
            return "No blockquoted evidence spans detected. This check did not assess factual claims."
        }
        let exact = findings.filter { $0.status == .exactMatch }.count
        let unresolved = findings.count - exact
        return "\(exact) of \(findings.count) quoted span(s) matched the attached drafts; \(unresolved) need review. Exact-text check only; claims remain unverified."
    }

    public var limitation: String {
        "A matching quote does not prove the surrounding claim, source truth, or that a draft matches the saved file."
    }

    private struct QuotedSpan {
        let text: String
        let citation: String?
    }

    private static func extractBlockQuotes(_ answer: String) -> [QuotedSpan] {
        let lines = normalized(answer).components(separatedBy: "\n")
        var spans: [QuotedSpan] = []
        var index = 0
        var inFence = false

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                index += 1
                continue
            }
            guard !inFence, let firstQuote = quotePayload(lines[index]) else {
                index += 1
                continue
            }

            let preceding = lines[max(0, index - 3)..<index]
            let citation = preceding.reversed().compactMap(citationLabel).first
            var payload = [firstQuote]
            index += 1
            while index < lines.count {
                if let next = quotePayload(lines[index]) {
                    payload.append(next)
                    index += 1
                } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          index + 1 < lines.count, quotePayload(lines[index + 1]) != nil {
                    payload.append("")
                    index += 1
                } else {
                    break
                }
            }
            let text = unwrappedQuotation(payload.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            if !text.isEmpty { spans.append(QuotedSpan(text: text, citation: citation)) }
        }
        return spans
    }

    private static func quotePayload(_ line: String) -> String? {
        let trimmed = line.drop(while: \.isWhitespace)
        guard trimmed.first == ">" else { return nil }
        var payload = String(trimmed.dropFirst())
        if payload.first == " " { payload.removeFirst() }
        return payload
    }

    private static func citationLabel(_ line: String) -> String? {
        let lower = line.lowercased()
        guard let range = lower.range(of: "source:") ?? lower.range(of: "evidence:") else { return nil }
        let remainder = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    private static func unwrappedQuotation(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»")]
        guard text.count >= 2, pairs.contains(where: { text.first == $0.0 && text.last == $0.1 }) else {
            return text
        }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func citation(_ label: String, names: String) -> Bool {
        let cleaned = label.trimmingCharacters(in: CharacterSet(charactersIn: " *`[]()"))
        return cleaned.localizedCaseInsensitiveContains(names)
            || names.localizedCaseInsensitiveContains(cleaned)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
