import Foundation

/// Operator-authored authorization boundary for outward browser and probe actions.
///
/// This is the Phase 1 bug-bounty control: before Wampum contacts any non-loopback
/// destination it must match a host the operator explicitly listed as in scope for the
/// active case. The gate is fail-closed — an empty scope authorizes nothing, so a case
/// with no declared scope cannot reach the outside at all. Matching is on the URL host
/// only; paths, ports and queries never widen authorization.
public struct AuthorizedScope: Codable, Sendable, Equatable {
    /// Normalized, lowercased entries. An empty set authorizes no outward host.
    public let entries: [String]

    public init(_ raw: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        for value in raw.map(Self.normalize) where !value.isEmpty && seen.insert(value).inserted {
            kept.append(value)
        }
        entries = kept
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Reduce a raw operator entry to a bare host pattern. Tolerates a pasted scheme,
    /// path or port so an operator can paste a URL, but only the host authority is kept.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
        value = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        if value.hasPrefix("[") { // bracketed IPv6 literal, drop any trailing :port after the bracket
            if let close = value.firstIndex(of: "]") { value = String(value[...close]) }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":"),
                  !value[value.index(after: colon)...].isEmpty,
                  value[value.index(after: colon)...].allSatisfy(\.isNumber) {
            // Single colon = host:port; strip the port. Two or more colons = a bare IPv6 literal
            // (which must be bracketed to carry a port), so leave it intact rather than mangle it.
            value = String(value[..<colon])
        }
        return value
    }

    /// A valid entry is a bare host (`api.example.com`), a subdomain wildcard
    /// (`*.example.com`, subdomains only), or an apex+subdomain wildcard (`.example.com`).
    public static func isValidEntry(_ entry: String) -> Bool {
        let host: String
        if entry.hasPrefix("*.") { host = String(entry.dropFirst(2)) }
        else if entry.hasPrefix(".") { host = String(entry.dropFirst()) }
        else { host = entry }
        guard !host.isEmpty, host.count <= 253, host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } &&
            !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    public func validate() throws {
        guard entries.count <= 200 else { throw WorkbenchError.invalid("Authorized scope has too many entries (max 200).") }
        for entry in entries where !Self.isValidEntry(entry) {
            throw WorkbenchError.invalid("Authorized scope entry is not a valid in-scope host or wildcard: \(entry)")
        }
    }

    public func matches(host: String) -> Bool {
        let target = Self.normalize(host)
        // Reject an empty host or one with an empty leading label (".api.example.com"): such a
        // malformed host must never slip past a subdomain wildcard.
        guard !target.isEmpty, !target.hasPrefix(".") else { return false }
        for entry in entries {
            if entry.hasPrefix("*.") {
                let base = String(entry.dropFirst(2))
                if target.hasSuffix("." + base) { return true } // subdomains only, not the apex
            } else if entry.hasPrefix(".") {
                let base = String(entry.dropFirst())
                if target == base || target.hasSuffix("." + base) { return true } // apex + subdomains
            } else if target == entry {
                return true
            }
        }
        return false
    }

    /// Returns the authorized host, or throws a fail-closed authorization error. Loopback
    /// is the caller's concern; this only answers whether the host is operator-authorized.
    @discardableResult
    public func authorize(_ url: URL) throws -> String {
        guard let host = url.host, !host.isEmpty else {
            throw WorkbenchError.invalid("Destination has no host to authorize.")
        }
        guard !isEmpty else {
            throw WorkbenchError.invalid("No authorized scope is defined for this case. Add the program's in-scope hosts to the case contract before any outward action.")
        }
        guard matches(host: host) else {
            throw WorkbenchError.invalid("Destination host \(host) is outside the case's authorized scope. Only operator-authorized in-scope targets may be contacted.")
        }
        return host
    }
}
