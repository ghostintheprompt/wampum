import Foundation
import CryptoKit

private final class ReplayNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // a redirect can cross an access-control boundary; never auto-follow.
    }
}

/// One test identity for a matched access-control run: a label, whether that identity is
/// *supposed* to have access (the operator's expectation), and the headers that authenticate
/// it (e.g. Authorization). The replayer sends the same request under each identity.
public struct ReplayIdentity: Sendable, Equatable {
    public let label: String
    public let authorized: Bool
    public let headers: [String: String]
    public init(label: String, authorized: Bool, headers: [String: String]) {
        self.label = label; self.authorized = authorized; self.headers = headers
    }
}

public struct ReplayResult: Sendable {
    public let identity: String
    public let authorized: Bool
    public let status: Int
    public let body: Data
    public let bodySHA256: String
    public var observation: ResponseObservation {
        ResponseObservation(label: identity, authorized: authorized, status: status, bodySHA256: bodySHA256, bodyBytes: body.count)
    }
}

/// Sends a reviewed request to an in-scope target under one or more identities and captures
/// the responses, so `ResponseComparison` can judge an access-control test and the captured
/// bodies can be pinned as evidence. Unlike the loopback-only tools, this reaches real
/// in-scope targets (that is the point in an engagement), but it is fail-closed on the case
/// `AuthorizedScope`: an out-of-scope host is refused before any request leaves. Redirects are
/// refused, and every decision is recorded to the network-events ledger (host only).
public actor RequestReplayer {
    private let guardrail: NetworkGuard
    public init(guardrail: NetworkGuard) { self.guardrail = guardrail }

    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    public func send(method rawMethod: String, url: URL, baseHeaders: [String: String] = [:], body: Data? = nil,
                     identity: ReplayIdentity, scope: AuthorizedScope, maxBody: Int = 2_097_152, timeout: TimeInterval = 20) async throws -> ReplayResult {
        let method = rawMethod.uppercased()
        guard Self.allowedMethods.contains(method) else { throw WorkbenchError.invalid("Unsupported HTTP method: \(rawMethod)") }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw WorkbenchError.invalid("Replay target must be an HTTP(S) URL without embedded credentials.")
        }
        let host = try scope.authorize(url)   // fail-closed on the case scope
        let destination = "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        do {
            try await guardrail.record(component: "Request replayer", destination: destination, decision: "REPLAY_INSCOPE", detail: "\(method) as identity \(identity.label)")
        } catch { /* ledger is best-effort; scope enforcement already passed */ }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in baseHeaders { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in identity.headers { request.setValue(v, forHTTPHeaderField: k) }  // identity headers win

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: ReplayNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkbenchError.invalid("No HTTP response from \(destination).") }
        guard data.count <= maxBody else { throw WorkbenchError.invalid("Response body exceeds the capture limit (\(maxBody) bytes); raise it deliberately.") }
        try? await guardrail.record(component: "Request replayer", destination: destination, decision: "REPLAY_RESPONSE", detail: "HTTP \(http.statusCode) as \(identity.label); redirects not followed")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ReplayResult(identity: identity.label, authorized: identity.authorized, status: http.statusCode,
                            body: data, bodySHA256: digest)
    }
}
