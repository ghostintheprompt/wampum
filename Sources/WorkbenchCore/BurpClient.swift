import Foundation

private final class BurpNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Drives a local Burp Suite Professional REST API. Like the Ollama client, it connects
/// only to loopback (Burp's REST API binds to 127.0.0.1) and refuses redirects. Before a
/// scan is submitted, every target URL's host is authorized against the active case scope,
/// and the case scope is mirrored into Burp's scan scope so Burp will not crawl out of
/// bounds. Nothing is sent that is not host-authorized.
///
/// The REST scan-config schema varies by Burp version; the body here (urls + a scope
/// include list) is the documented v0.1 shape and should be confirmed against the installed
/// Burp before a live engagement — a passing loopback fixture test is not a live Burp run.
public actor BurpClient {
    public let base: URL
    private let apiKey: String?
    private let guardrail: NetworkGuard

    public init(base: URL = URL(string: "http://127.0.0.1:1337")!, apiKey: String? = nil, guardrail: NetworkGuard = NetworkGuard()) throws {
        guard NetworkGuard.isLoopback(base) else { throw WorkbenchError.invalid("Burp REST API must be a loopback address (Burp binds its API to 127.0.0.1).") }
        if let apiKey {
            guard !apiKey.isEmpty, apiKey.count <= 128, apiKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw WorkbenchError.invalid("Burp API key must be alphanumeric.")
            }
        }
        self.base = base; self.apiKey = apiKey; self.guardrail = guardrail
    }

    private func endpoint(_ path: String) -> URL {
        var url = base
        if let apiKey { url.appendPathComponent(apiKey) }
        url.appendPathComponent(path)
        return url
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.proxyConfigurations = []
        return URLSession(configuration: configuration, delegate: BurpNoRedirects(), delegateQueue: nil)
    }

    /// Authorize every target against the case scope, then submit a scope-bounded scan.
    /// Returns a receipt whose detail carries the Burp task id (from the Location header).
    public func startScan(urls: [String], scope: AuthorizedScope) async throws -> ToolReceipt {
        guard !urls.isEmpty else { throw WorkbenchError.invalid("Declare at least one target URL to scan.") }
        var hosts: [String] = []
        for raw in urls {
            guard let url = URL(string: raw), let host = url.host, !host.isEmpty, (url.scheme == "http" || url.scheme == "https") else {
                throw WorkbenchError.invalid("Scan target must be an HTTP(S) URL with a host: \(raw)")
            }
            _ = try scope.authorize(url)
            hosts.append(host)
        }
        // Mirror the case scope into Burp's scan scope: only the authorized hosts are in bounds.
        let include = Array(Set(hosts)).sorted().map { ["rule": "^https?://([^/]+\\.)?\(NSRegularExpression.escapedPattern(for: $0))/"] }
        let body: [String: Any] = ["urls": urls, "scope": ["type": "SimpleScope", "include": include]]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint("v0.1/scan"))
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        try await guardrail.authorize(request.url!, component: "Burp REST", operation: "start scan (\(hosts.count) host(s))")

        var receipt = ToolReceipt(tool: "burp", action: "scan", targets: hosts, argument: String(decoding: payload, as: UTF8.self))
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WorkbenchError.invalid("No HTTP response from Burp.") }
            guard (200..<300).contains(http.statusCode) else {
                receipt.outcome = .failed; receipt.detail = "Burp returned HTTP \(http.statusCode)."
                throw WorkbenchError.invalid(receipt.detail)
            }
            let task = (http.value(forHTTPHeaderField: "Location") ?? "").split(separator: "/").last.map(String.init) ?? ""
            receipt.outcome = .succeeded
            receipt.detail = task.isEmpty ? "Scan accepted (HTTP \(http.statusCode))." : "Scan task \(task) accepted."
            receipt.resultSHA256 = ToolReceipt.hash(String(decoding: data, as: UTF8.self))
            return receipt
        } catch let error as WorkbenchError {
            throw error
        } catch {
            throw WorkbenchError.invalid("Burp scan request failed: \(error.localizedDescription)")
        }
    }

    /// One Burp scanner issue, as a LEAD. A scanner issue is not proof of impact — it is a
    /// candidate the researcher must reproduce and capture before it can back a Finding. It
    /// is imported into the ledger as a sourceReport, never a hostReceipt, so the Phase 2
    /// verification loop structurally cannot promote it on its own.
    public struct BurpIssue: Codable, Equatable, Sendable {
        public let name: String
        public let severity: String
        public let confidence: String
        public let origin: String
        public let path: String?
        /// An out-of-band / Collaborator interaction: the target actually called back to a
        /// unique Collaborator host our payload triggered. That is observed impact (SSRF,
        /// blind injection), not a pattern match — so it imports as a hostReceipt, not a lead.
        public var isOutOfBand: Bool {
            let n = name.lowercased()
            return n.contains("out-of-band") || n.contains("out of band")
                || n.contains("external service interaction") || n.contains("collaborator")
                || n.contains("oob")
        }
    }

    /// Fetch the scanner issues for a task. Only issues whose origin host is inside the case
    /// scope are returned (defense in depth; the scan was already scope-bounded).
    public func scanIssues(taskID: String, scope: AuthorizedScope) async throws -> [BurpIssue] {
        let (_, raw) = try await scanStatus(taskID: taskID)
        struct Wrapper: Decodable { struct Event: Decodable { let issue: BurpIssue? }; let issue_events: [Event]? }
        let issues = (try JSONDecoder().decode(Wrapper.self, from: raw).issue_events ?? []).compactMap { $0.issue }
        return issues.filter { issue in
            guard let url = URL(string: issue.origin) else { return false }
            return (try? scope.authorize(url)) != nil
        }
    }

    /// Read a scan task's status. Returns the decoded JSON and a short status summary.
    public func scanStatus(taskID: String) async throws -> (summary: String, raw: Data) {
        guard !taskID.isEmpty, taskID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw WorkbenchError.invalid("Invalid Burp task id.")
        }
        var request = URLRequest(url: endpoint("v0.1/scan/\(taskID)"))
        request.timeoutInterval = 20
        try await guardrail.authorize(request.url!, component: "Burp REST", operation: "scan status \(taskID)")
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkbenchError.invalid("Burp status request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["scan_status"] as? String
        return (status ?? "unknown", data)
    }
}
