import Foundation
public struct LocalModel: Decodable, Identifiable {
    public let name: String
    public let size: Int64?
    public let capabilities: [String]?
    public var id: String { name }
}
public struct ModelInfo: Decodable { public let capabilities: [String]? }
public struct ChatReply: Decodable {
    public struct Message: Decodable { public let content: String; public let thinking: String? }
    public let message: Message
    public let prompt_eval_count: Int?
    public let eval_count: Int?
    public let eval_duration: Double?
    public let load_duration: Double?
    public let total_duration: Double?
    public let done_reason: String?
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    let guardrail: NetworkGuard
    init(_ guardrail:NetworkGuard){self.guardrail=guardrail}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        Task { try? await guardrail.record(component:"Ollama redirect",destination:"\(request.url?.scheme ?? "unknown")://\(request.url?.host ?? "unknown")",decision:"REDIRECT_BLOCKED",detail:"All redirects refused; no follow-up request sent") };completionHandler(nil)
    }
}
public struct OllamaClient {
    public let base: URL
    public let guardrail: NetworkGuard
    public init(base: URL = URL(string:"http://127.0.0.1:11434")!, guardrail:NetworkGuard = NetworkGuard()) throws {
        guard NetworkGuard.isLoopback(base) else { throw WorkbenchError.invalid("This build connects only to local Ollama.") }
        self.base = base;self.guardrail=guardrail
    }
    func request(_ path: String, body: [String:Any]? = nil, timeout: TimeInterval = 20) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent(path))
        try await guardrail.authorize(request.url!,component:"Ollama",operation:path)
        request.timeoutInterval = timeout
        if let body = body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField:"Content-Type") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.proxyConfigurations = []
        let session = URLSession(configuration: configuration, delegate: NoRedirects(guardrail), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }; throw error }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw WorkbenchError.invalid(String(data: data.prefix(2000), encoding:.utf8) ?? "Ollama request failed.") }
        return data
    }
    public func models() async throws -> [LocalModel] {
        struct List: Decodable { let models: [LocalModel] }
        return try JSONDecoder().decode(List.self, from: await request("api/tags")).models.filter { $0.capabilities == nil || $0.capabilities!.contains("completion") }
    }
    public func show(_ model: String) async throws -> ModelInfo { try JSONDecoder().decode(ModelInfo.self, from: await request("api/show", body:["model":model])) }
    public func chat(model: String, packet: ContextPacket, context: Int, thinking: Bool, supportsThinking: Bool, images: [String] = [], timeout: TimeInterval = 600) async throws -> ChatReply {
        var body: [String:Any] = ["model":model, "messages":packet.messages, "stream":false, "keep_alive":"5m", "options":["num_ctx":context,"num_predict":1024,"temperature":0.2]]
        if !images.isEmpty {
            var messages=packet.messages.map { $0 as [String:Any] }
            guard let last=messages.lastIndex(where:{$0["role"] as? String == "user"}) else {throw WorkbenchError.invalid("Images require a user message.")}
            messages[last]["images"]=images;body["messages"]=messages
        }
        if supportsThinking { body["think"] = thinking }
        return try JSONDecoder().decode(ChatReply.self, from: await request("api/chat", body:body, timeout:timeout))
    }
    public func unload(_ model: String) async throws { _ = try await request("api/generate", body:["model":model,"keep_alive":0]) }
}

public struct BrowserPlanReply: Decodable {
    public struct Message:Decodable {public let content:String;public let tool_calls:[Call]?}
    public struct Call:Decodable {public let function:Function}
    public struct Function:Decodable {public let name:String;public let arguments:JSONValue}
    public let message:Message
}
extension OllamaClient {
    public func planBrowser(model:String,packet:ContextPacket,context:Int,tools:[MCPTool],supportsThinking:Bool) async throws -> BrowserPlanReply {
        var body:[String:Any]=["model":model,"messages":packet.messages,"stream":false,"keep_alive":"5m","options":["num_ctx":context,"num_predict":512,"temperature":0.1],"tools":try JSONSerialization.jsonObject(with:JSONEncoder().encode(tools.map(\.ollama)))]
        if supportsThinking {body["think"]=false}
        return try JSONDecoder().decode(BrowserPlanReply.self,from:await request("api/chat",body:body,timeout:180))
    }
}
