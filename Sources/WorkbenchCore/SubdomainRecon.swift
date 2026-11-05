import Foundation

/// Ingests subdomain-enumeration output (e.g. `subfinder -oJ` JSONL, or a plain host list) and
/// batch-classifies takeover leads through `TakeoverProbe`, ranked strongest-first. Closes the
/// recon gap: Wampum already scores ffuf/nmap leads; this does the same for subdomain enum +
/// dangling-CNAME takeover. Pure parsing/classification — DNS/HTTP observation is the caller's.
public enum SubdomainImport {
    /// Parse hosts from subfinder output. Accepts JSONL ({"host":"a.b.com",...} per line) or a
    /// plain newline-separated host list. Deduped, lowercased, basic host validation.
    public static func hosts(from data: Data) throws -> [String] {
        guard data.count <= 33_554_432 else { throw WorkbenchError.invalid("subdomain output exceeds 32 MB.") }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkbenchError.invalid("subdomain output is not UTF-8.") }
        var out: [String] = []; var seen = Set<String>()
        for raw in text.split(separator: "\n") {
            var host = raw.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { continue }
            if host.hasPrefix("{"), let d = host.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let h = o["host"] as? String { host = h }
            host = host.lowercased()
            let ok = host.contains(".") && host.count <= 253 &&
                host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
            guard ok, seen.insert(host).inserted else { continue }
            out.append(host)
        }
        return out
    }
}

extension TakeoverProbe {
    /// One observed subdomain record for batch classification.
    public struct Record: Codable, Equatable, Sendable {
        public let host: String
        public let cnameTarget: String
        public let targetResolves: Bool
        public let body: String
        public init(host: String, cnameTarget: String, targetResolves: Bool, body: String = "") {
            self.host = host; self.cnameTarget = cnameTarget; self.targetResolves = targetResolves; self.body = body
        }
    }

    /// Classify a batch and sort strongest-first — the takeover leads to chase sit at the top.
    public static func rank(_ records: [Record]) -> [Verdict] {
        let order: [Confidence: Int] = [.strong: 0, .moderate: 1, .weak: 2, .clear: 3]
        return records
            .map { classify(host: $0.host, cnameTarget: $0.cnameTarget, targetResolves: $0.targetResolves, body: $0.body) }
            .sorted { (order[$0.confidence] ?? 9, $0.host) < (order[$1.confidence] ?? 9, $1.host) }
    }
}
