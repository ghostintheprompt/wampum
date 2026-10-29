import Foundation

/// Append-only local artifacts per request. Missing terminal records mean unknown, never success.
/// Same-account files provide auditability, not authenticated execution proof.
public struct ResearchTurnJournal: Sendable {
    public let directory: URL
    public init(root: URL, messages: [[String: String]], model: String, context: Int,
                thinking: Bool, supportsThinking: Bool, fingerprint: String) throws {
        directory = root.appendingPathComponent("research-turns/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request: [String: Any] = ["schema": "wampum-research-turn/v1", "state": "prepared",
            "model": model, "context": context, "thinking": thinking, "supportsThinking": supportsThinking,
            "messages": messages, "researchFingerprint": fingerprint,
            "assurance": "Logical reviewed request, not exact HTTP wire bytes. No automatic replay after interruption."]
        try write(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), name: "request.json")
    }
    public func recordRawResponse(_ data: Data) throws { try write(data, name: "response.json") }
    public func recordTerminal(_ state: String, detail: String) throws {
        guard ["responseSaved", "failedOrCancelled"].contains(state) else { throw WorkbenchError.invalid("Invalid research terminal state.") }
        try write(JSONSerialization.data(withJSONObject: ["state": state, "detail": detail], options: [.sortedKeys]), name: "terminal.json")
    }
    private func write(_ data: Data, name: String) throws {
        try IntegrityCheck.writeNew(data, to: directory.appendingPathComponent(name).path)
    }
}
