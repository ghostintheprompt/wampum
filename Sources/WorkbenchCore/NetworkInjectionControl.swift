import Foundation

/// Scope-gated network injection plan (ported from the 2026 `wampum_mitm_injector` module):
/// for an AUTHORIZED internal-network engagement, inject an indirect-prompt-injection / RAG
/// contamination payload into HTTP responses for an in-scope host (rogue-AP / MitM), so a
/// RAG-backed internal assistant on that network receives the vector in its retrieved context.
///
/// This is lawful ONLY inside a signed engagement whose rules of engagement cover that network
/// and those hosts. Wampum enforces that the same way it enforces everything else, and the gate
/// is the control:
///   - Fail-closed on the case `AuthorizedScope`: the target host must be explicitly in scope, or
///     `plan` throws before anything is built. Loopback is not a MitM target.
///   - Pure here: `plan` only BUILDS a host-filtered guest directive + a receipt for operator
///     review. The injection itself runs in the operator's authorized Kali guest (like the
///     wireless capture path), never from Wampum directly, and only within the RoE.
///   - Every run produces a `ToolReceipt`; a resulting observation is still a LEAD promoted only
///     through the evidence + FindingVerification workflow.
public enum NetworkInjectionControl {
    public struct Plan: Sendable {
        public let targetHost: String
        public let payload: String
        /// The host-filtered directive to run in the authorized Kali guest (operator-reviewed).
        public let guestDirective: [String]
        public let receipt: ToolReceipt
    }

    public static func plan(targetHost: String, payload: String, scope: AuthorizedScope) throws -> Plan {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkbenchError.invalid("No injection payload.") }
        guard !payload.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkbenchError.invalid("Payload contains a NUL byte.")
        }
        // Fail-closed authorization: the target host must be in the case RoE. Reusing the exact
        // Phase 1 scope semantics means an out-of-scope host is refused before any plan is built.
        guard let host = try ToolScopeGate.authorize(targets: [targetHost], scope: scope).first else {
            throw WorkbenchError.invalid("No in-scope target host to authorize for injection.")
        }
        // A host-FILTERED injection directive: the proxy only rewrites traffic for the authorized
        // host, never blanket traffic. Operator reviews this before it runs in the Kali guest.
        let guestDirective = [
            "wampum-mitm-inject",
            "--roe-host", host,
            "--only-host", host,          // restrict injection to the in-scope host
            "--inject-http-response",
            "--payload-stdin",            // payload passed via stdin, not argv, to avoid leakage
        ]
        let receipt = ToolReceipt(
            tool: "net-inject", action: "http-inject", targets: [host],
            argument: "inject RAG/prompt vector into in-scope \(host)",
            detail: "Scope-gated MitM injection plan for an AUTHORIZED engagement only; host-filtered to \(host). Runs in the operator's Kali guest under the RoE; any observed effect is a LEAD to capture and promote."
        )
        return Plan(targetHost: host, payload: payload, guestDirective: guestDirective, receipt: receipt)
    }
}
