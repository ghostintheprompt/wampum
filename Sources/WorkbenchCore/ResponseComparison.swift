import Foundation

/// One observed response for a matched access-control test: the same operation run under a
/// different identity. `authorized` records whether that identity is *supposed* to have
/// access to the resource — the operator's expectation, not something inferred from the
/// response. The body is carried as a hash so comparisons never hold response contents.
public struct ResponseObservation: Codable, Equatable, Sendable {
    public let label: String        // "owner", "attacker", "revoked-session"
    public let authorized: Bool     // is this identity supposed to have access?
    public let status: Int
    public let bodySHA256: String
    public let bodyBytes: Int
    public init(label: String, authorized: Bool, status: Int, bodySHA256: String, bodyBytes: Int) {
        self.label = label; self.authorized = authorized; self.status = status
        self.bodySHA256 = bodySHA256; self.bodyBytes = bodyBytes
    }
    var isSuccess: Bool { (200..<300).contains(status) }
}

/// Deterministic side-by-side comparison of matched responses for access-control research.
/// It raises a SIGNAL (a lead) when an unauthorized identity was not properly denied — most
/// strongly when it received the exact response an authorized identity did. A signal is never
/// a finding on its own: the captured response pair must be pinned as evidence and promoted
/// through `FindingVerification`. This only reads status and body hashes; it proves nothing
/// about intent and does not fetch anything.
public enum ResponseComparison {
    public struct Signal: Codable, Equatable, Sendable {
        public enum Classification: String, Codable, Sendable { case none, notDenied, brokenAccessControl }
        public let classification: Classification
        public let detail: String
        public let unauthorizedLabels: [String]
        public var present: Bool { classification != .none }
    }

    public static func evaluate(_ observations: [ResponseObservation]) throws -> Signal {
        guard observations.count >= 2 else { throw WorkbenchError.invalid("A matched comparison needs at least two identities.") }
        let labels = observations.map(\.label)
        guard Set(labels).count == labels.count else { throw WorkbenchError.invalid("Observation labels must be unique.") }
        let authorizedSuccess = observations.filter { $0.authorized && $0.isSuccess }
        let unauthorized = observations.filter { !$0.authorized }
        guard !unauthorized.isEmpty else { throw WorkbenchError.invalid("Declare at least one unauthorized identity to test.") }

        // Strongest: an unauthorized identity received the exact body an authorized one did.
        let baselineHashes = Set(authorizedSuccess.map(\.bodySHA256))
        let brokeIn = unauthorized.filter { $0.isSuccess && baselineHashes.contains($0.bodySHA256) }
        if !brokeIn.isEmpty {
            return Signal(classification: .brokenAccessControl,
                          detail: "Unauthorized identity received a response byte-identical to an authorized one — a broken-access-control lead. Reproduce and pin both captured responses to promote.",
                          unauthorizedLabels: brokeIn.map(\.label))
        }
        // Weaker: an unauthorized identity got any success instead of being denied.
        let notDenied = unauthorized.filter { $0.isSuccess }
        if !notDenied.isEmpty {
            return Signal(classification: .notDenied,
                          detail: "Unauthorized identity was not denied (received a success status). May be an empty or different resource — verify the response contents.",
                          unauthorizedLabels: notDenied.map(\.label))
        }
        return Signal(classification: .none, detail: "Every unauthorized identity was denied (no success). No access-control signal.", unauthorizedLabels: [])
    }
}
