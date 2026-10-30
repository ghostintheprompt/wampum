import Foundation
import CryptoKit

/// Shared foundation for driving external pen-test tools (Docker, Burp, and later nmap,
/// ffuf, …) from Wampum. Every tool path goes through the same two controls so a new tool
/// is a thin addition, not a new trust path:
///
///   1. `ToolScopeGate` — the operator declares the explicit target(s) of an invocation and
///      each is authorized against the active case's Phase 1 `AuthorizedScope`, fail-closed.
///      Wampum does not guess targets out of a freeform command; it gates what the operator
///      declares and refuses a network-capable action with no declared, in-scope target.
///   2. `ToolReceipt` — a hashed record of exactly what was invoked and what came back, so a
///      Phase 2 claim can cite tool evidence the same way it cites a browser capture.
public enum ToolScopeGate {
    /// Normalize a declared target (a URL or a bare host) to the host the scope matches on.
    public static func host(of target: String) throws -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkbenchError.invalid("Empty target declared.") }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty { return host }
        let host = AuthorizedScope.normalize(trimmed)
        guard !host.isEmpty else { throw WorkbenchError.invalid("Target has no host to authorize: \(target)") }
        return host
    }

    /// Authorize every declared target against the scope. Returns the normalized hosts, or
    /// throws on the first out-of-scope target. Requiring at least one target is the caller's
    /// decision (a read-only local action may legitimately declare none).
    @discardableResult
    public static func authorize(targets: [String], scope: AuthorizedScope) throws -> [String] {
        var hosts: [String] = []
        for target in targets {
            let host = try host(of: target)
            // Reuse the exact Phase 1 fail-closed semantics by building a host URL to authorize.
            guard let url = URL(string: "https://\(host)") else { throw WorkbenchError.invalid("Target host is malformed: \(host)") }
            _ = try scope.authorize(url)
            hosts.append(host)
        }
        return hosts
    }
}

public struct ToolReceipt: Codable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case planned, succeeded, failed }
    public let id: UUID
    public let at: Date
    public let tool: String          // "docker", "burp", …
    public let action: String        // the subcommand / endpoint
    public let targets: [String]     // normalized, authorized hosts (never a path or query)
    public let argumentSHA256: String
    public var outcome: Outcome
    public var detail: String
    public var resultSHA256: String?
    public init(tool: String, action: String, targets: [String], argument: String, outcome: Outcome = .planned, detail: String = "") {
        id = UUID(); at = Date(); self.tool = tool; self.action = action; self.targets = targets
        argumentSHA256 = ToolReceipt.hash(argument); self.outcome = outcome; self.detail = detail
    }
    public static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// Durable, bounded local store of tool receipts, and the bridge that turns one into
/// evidence: a receipt written to disk and pinned into the case ledger as a `hostReceipt`,
/// so a Burp or Docker result can back a Phase 2 Finding exactly like a browser capture.
public struct ToolReceiptStore {
    public let directory: URL
    public init(root: URL) throws {
        directory = root.appendingPathComponent("tool-receipts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private var file: URL { directory.appendingPathComponent("recent.json") }
    public func load() throws -> [ToolReceipt] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 2_097_152 else { throw WorkbenchError.invalid("Tool receipt history is too large; inspect it before continuing.") }
        return try JSONDecoder().decode([ToolReceipt].self, from: data)
    }
    public func save(_ receipts: [ToolReceipt]) throws {
        try JSONEncoder().encode(Array(receipts.suffix(200))).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Write one receipt to its own immutable evidence file and return its absolute path.
    /// The file is what gets pinned/hashed into the ledger; the receipt is never mutated after.
    public func writeEvidenceFile(_ receipt: ToolReceipt) throws -> URL {
        let url = directory.appendingPathComponent("evidence-" + receipt.id.uuidString + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
