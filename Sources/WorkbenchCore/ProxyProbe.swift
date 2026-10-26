import Foundation
import Network

public struct ProxySpec:Equatable {
    public let scheme:String
    public let host:String
    public let port:UInt16
    public init(_ value:String)throws {
        guard let url=URL(string:value),let scheme=url.scheme?.lowercased(),["socks5","http","https"].contains(scheme),let host=url.host,!host.isEmpty,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,["","/"].contains(url.path),let port=url.port,(1...65535).contains(port) else {throw WorkbenchError.invalid("Use socks5://host:port, http://host:port, or https://host:port. Credentials and paths are not supported.")}
        self.scheme=scheme;self.host=host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()):host;self.port=UInt16(port)
    }
    public var description:String{"\(scheme)://\(host.contains(":") ? "["+host+"]":host):\(port)"}
    public func configuration()->ProxyConfiguration {
        let endpoint=NWEndpoint.hostPort(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:port)!)
        var proxy = scheme=="socks5" ? ProxyConfiguration(socksv5Proxy:endpoint):ProxyConfiguration(httpCONNECTProxy:endpoint,tlsOptions:scheme=="https" ? NWProtocolTLS.Options():nil)
        proxy.allowFailover=false
        proxy.excludedDomains=[]
        return proxy
    }
}
public struct ProxyProbeReview:Identifiable {
    public let id=UUID()
    public let url:URL
    public let proxy:ProxySpec
    public init(urlString:String,proxyString:String)throws {
        guard let url=URL(string:urlString),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,url.fragment==nil else{throw WorkbenchError.invalid("Use an HTTPS destination without embedded credentials or a fragment.")}
        self.url=url;self.proxy=try ProxySpec(proxyString)
    }
}
private final class ProbeRedirectBlocker:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
public actor ProxyProbeClient {
    private var used:Set<UUID>=[]
    private let guardrail:NetworkGuard
    public init(guardrail:NetworkGuard){self.guardrail=guardrail}
    public func performApproved(_ review:ProxyProbeReview)async throws->String {
        guard used.insert(review.id).inserted else{throw WorkbenchError.invalid("This approval has already been used. Prepare a new request.")}
        let destination="https://\(review.url.host!):\(review.url.port ?? 443)"
        try await guardrail.record(component:"Approved proxy probe",destination:destination,decision:"PROXY_HEAD_APPROVED_ONCE",detail:"via \(review.proxy.description); no direct fallback; no project context attached")
        let configuration=URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations=[review.proxy.configuration()]
        configuration.httpShouldSetCookies=false;configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil;configuration.urlCache=nil;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session=URLSession(configuration:configuration,delegate:ProbeRedirectBlocker(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:review.url);request.httpMethod="HEAD";request.timeoutInterval=15;request.setValue("Wampum/0.1",forHTTPHeaderField:"User-Agent")
        do{
            let(_,response)=try await session.data(for:request)
            guard let http=response as? HTTPURLResponse else{throw WorkbenchError.invalid("No HTTP response.")}
            let status=http.statusCode
            try await guardrail.record(component:"Approved proxy probe",destination:destination,decision:"PROXY_HEAD_RESPONSE",detail:"HTTP \(status); redirects not followed")
            return "HTTP \(status) from \(destination) via \(review.proxy.description). Redirects not followed. No content body requested."
        }catch{
            try? await guardrail.record(component:"Approved proxy probe",destination:destination,decision:"PROXY_REQUEST_FAILED",detail:"Failed without direct fallback; inspect proxy and connectivity")
            throw WorkbenchError.invalid("Proxy request failed. No direct fallback was permitted. \(error.localizedDescription)")
        }
    }
}
