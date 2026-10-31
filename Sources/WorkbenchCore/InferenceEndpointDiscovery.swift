import Foundation

/// Scope-gated discovery of exposed AI inference endpoints (ported from the 2026 "Local Inference
/// Endpoint Discovery" module). For an in-scope host, probe the well-known LLM API paths and
/// classify which are reachable — an exposed internal model API is a LEAD worth testing with the
/// AI red-team suite. Pure here: `candidatePaths`/`classify` are deterministic; the live probing
/// is a scope-gated model-layer step (host must be in the case AuthorizedScope, fail-closed).
public enum InferenceEndpointDiscovery {
    public struct Hit: Codable, Sendable, Equatable {
        public let path: String
        public let status: Int
        public let kind: String
        public init(path: String, status: Int, kind: String) { self.path = path; self.status = status; self.kind = kind }
    }

    /// Well-known inference API paths to probe on an in-scope host.
    public static func candidatePaths() -> [String] {
        ["/api/tags", "/api/generate", "/v1/models", "/v1/chat/completions",
         "/openai/v1/models", "/.well-known/ai-plugin.json", "/health"]
    }

    /// Classify a probed response as an inference endpoint. Returns a kind label, or nil if it
    /// does not look like an exposed model API (so a 404/unrelated page is not a false lead).
    public static func classify(path: String, status: Int, body: String) -> String? {
        let b = body.lowercased()
        if status == 404 { return nil }
        if path.contains("/api/tags"), b.contains("\"models\"") { return "ollama" }
        if path.contains("/v1/models") || path.contains("/openai/v1/models"),
           b.contains("\"object\"") || b.contains("\"data\"") || b.contains("\"id\"") { return "openai-compatible" }
        if path.contains("ai-plugin"), b.contains("schema_version") { return "ai-plugin-manifest" }
        if path.contains("/v1/chat/completions"), (200..<500).contains(status) { return "openai-chat-reachable" }
        if path.contains("/api/generate"), (200..<500).contains(status) { return "ollama-generate-reachable" }
        return nil
    }
}
