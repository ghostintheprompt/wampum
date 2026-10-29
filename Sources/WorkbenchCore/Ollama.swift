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
    public func chat(model: String, packet: ContextPacket, context: Int, thinking: Bool, supportsThinking: Bool, images: [String] = [], timeout: TimeInterval = 600, onRawResponse: (@Sendable (Data) throws -> Void)? = nil) async throws -> ChatReply {
        var body: [String:Any] = ["model":model, "messages":packet.messages, "stream":false, "keep_alive":"5m", "options":["num_ctx":context,"num_predict":Self.responseTokenLimit(context:context,inputEstimate:packet.estimatedTokens),"temperature":0.2]]
        if !images.isEmpty {
            var messages=packet.messages.map { $0 as [String:Any] }
            guard let last=messages.lastIndex(where:{$0["role"] as? String == "user"}) else {throw WorkbenchError.invalid("Images require a user message.")}
            messages[last]["images"]=images;body["messages"]=messages
        }
        if supportsThinking { body["think"] = thinking }
        let raw = try await request("api/chat", body:body, timeout:timeout)
        try onRawResponse?(raw)
        return try JSONDecoder().decode(ChatReply.self, from: raw)
    }
    public static func responseTokenLimit(context:Int,inputEstimate:Int) -> Int {
        min(4096,max(1,context-inputEstimate-512))
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

private struct OllamaStreamPart:Decodable {
    struct Message:Decodable {let content:String?;let thinking:String?}
    let message:Message?;let done:Bool?;let done_reason:String?;let error:String?
    let prompt_eval_count:Int?;let eval_count:Int?;let eval_duration:Double?;let load_duration:Double?;let total_duration:Double?
}
extension OllamaClient {
    public func streamingChat(model:String,packet:ContextPacket,context:Int,thinking:Bool,supportsThinking:Bool,schemaJSON:Data?=nil,timeout:TimeInterval=900,onDelta:@Sendable(String)async throws->Void) async throws->ChatReply {
        var body:[String:Any]=["model":model,"messages":packet.messages,"stream":true,"keep_alive":"5m","options":["num_ctx":context,"num_predict":Self.responseTokenLimit(context:context,inputEstimate:packet.estimatedTokens),"temperature":0.2]]
        if supportsThinking {body["think"]=thinking}
        if let schemaJSON {body["format"]=try JSONSerialization.jsonObject(with:schemaJSON)}
        let url=base.appendingPathComponent("api/chat");try await guardrail.authorize(url,component:"Ollama",operation:"api/chat streaming")
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.timeoutInterval=timeout
        let configuration=URLSessionConfiguration.ephemeral;configuration.httpShouldSetCookies=false;configuration.connectionProxyDictionary=[:];configuration.proxyConfigurations=[]
        let session=URLSession(configuration:configuration,delegate:NoRedirects(guardrail),delegateQueue:nil);defer{session.invalidateAndCancel()}
        return try await withTaskCancellationHandler(operation:{
            do {
                let (bytes,response)=try await session.bytes(for:request)
                guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
                    var detail=Data();for try await byte in bytes {detail.append(byte);if detail.count>=2000{break}}
                    throw WorkbenchError.invalid(String(decoding:detail,as:UTF8.self))
                }
                var answer="",reasoning=""
                for try await line in bytes.lines {
                    try Task.checkCancellation();if line.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{continue}
                    let part=try JSONDecoder().decode(OllamaStreamPart.self,from:Data(line.utf8))
                    if let error=part.error {throw WorkbenchError.invalid(error)}
                    if let delta=part.message?.content,!delta.isEmpty {
                        guard answer.utf8.count+delta.utf8.count<=2_097_152 else{throw WorkbenchError.invalid("Response exceeded2MB; received text remains in the caller's checkpoint.")}
                        try await onDelta(delta);answer+=delta
                    }
                    if let delta=part.message?.thinking {reasoning+=delta}
                    if part.done==true {
                        return ChatReply(message:ChatReply.Message(content:answer,thinking:reasoning.isEmpty ? nil:reasoning),prompt_eval_count:part.prompt_eval_count,eval_count:part.eval_count,eval_duration:part.eval_duration,load_duration:part.load_duration,total_duration:part.total_duration,done_reason:part.done_reason)
                    }
                }
                throw WorkbenchError.invalid("Stream ended without a completion record; received text remains in the caller's checkpoint.")
            }catch{if Task.isCancelled{throw CancellationError()};throw error}
        },onCancel:{session.invalidateAndCancel()})
    }
}
