import Foundation

/// Shared foundation for Wampum's AI/LLM red-team testing modules (ported from the 2026
/// capability spec). These evaluate whether an AUTHORIZED target AI system is susceptible to a
/// class of attack — indirect prompt injection, tool weaponization, excessive agency, memory
/// poisoning, RAG contamination, guardrail bypass, multimodal injection — and whether a
/// defensive guard catches them.
///
/// The discipline is identical to the rest of Wampum, and it is the control:
///   - Every target is a scope-gated endpoint; the case `AuthorizedScope` decides what may be
///     touched, fail-closed. These are testers for authorized engagements, not weapons.
///   - Every probe yields a LEAD (`Signal`), never a finding on its own. A boundary crossing is
///     promoted only through captured evidence + operator review + `FindingVerification`.
///   - Pure/analysis cores (no network) so they are deterministically testable; the live send +
///     evidence capture is a separate model-layer step.
public enum AIRedTeam {
    /// An AI system under test. `endpoint` is the model/agent API URL; the host is authorized
    /// against the case scope by the caller before anything is sent.
    public struct Target: Codable, Sendable, Equatable {
        public let label: String
        public let endpoint: String
        public let model: String
        public init(label: String, endpoint: String, model: String) {
            self.label = label; self.endpoint = endpoint; self.model = model
        }
    }

    /// One attack attempt's recorded inputs — preserved verbatim as a test input (never hidden),
    /// matching the honesty constraint of the existing TestVariation module.
    public struct Attempt: Codable, Sendable, Equatable {
        public let technique: String        // "indirect-injection", "rag-contamination", …
        public let label: String            // human label for this attempt/variant
        public let payload: String          // the exact payload sent / embedded
        public let note: String
        public init(technique: String, label: String, payload: String, note: String = "") {
            self.technique = technique; self.label = label; self.payload = payload; self.note = note
        }
    }

    /// The deterministic verdict of a probe over an observed target response. Severity-free:
    /// `crossed == true` is a LEAD that a boundary was crossed, to verify + capture, not a finding.
    public struct Signal: Codable, Sendable, Equatable {
        public let technique: String
        public let crossed: Bool
        public let detail: String
        public let markers: [String]        // observable evidence markers found in the response
        public init(technique: String, crossed: Bool, detail: String, markers: [String] = []) {
            self.technique = technique; self.crossed = crossed; self.detail = detail; self.markers = markers
        }
        /// A crossing is a lead to promote through the evidence path, never a finding by itself.
        public var present: Bool { crossed }
        public var summary: String {
            crossed
            ? "LEAD — \(technique): boundary crossed (\(markers.joined(separator: ", "))). \(detail) Capture + verify to promote."
            : "\(technique): no boundary crossing observed. \(detail)"
        }
    }

    /// Case-insensitive presence of any marker string in a response body. Shared helper so every
    /// module detects a crossing the same way (the observed effect, not guessed intent).
    public static func markersPresent(_ needles: [String], in haystack: String) -> [String] {
        let hay = haystack.lowercased()
        return needles.filter { !$0.isEmpty && hay.contains($0.lowercased()) }
    }
}
