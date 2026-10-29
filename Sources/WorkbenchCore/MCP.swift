import Foundation
import Darwin

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String:JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null} else if let v=try? c.decode(Bool.self){self = .bool(v)} else if let v=try? c.decode(Double.self){self = .number(v)} else if let v=try? c.decode(String.self){self = .string(v)} else if let v=try? c.decode([String:JSONValue].self){self = .object(v)} else {self = .array(try c.decode([JSONValue].self))}
    }
    public func encode(to encoder:Encoder)throws {var c=encoder.singleValueContainer();switch self {case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .null:try c.encodeNil()}}
    public subscript(_ key:String)->JSONValue? {if case .object(let v)=self{return v[key]};return nil}
    public var string:String? {if case .string(let v)=self{return v};return nil}
    public var array:[JSONValue]? {if case .array(let v)=self{return v};return nil}
    public var isTrue:Bool {self == .bool(true)}
    public var pretty:String {(try? String(data:JSONEncoder.pretty.encode(self),encoding:.utf8)) ?? "null"}
    public var canonical:String {(try? String(data:JSONEncoder.sorted.encode(self),encoding:.utf8)) ?? "null"}
}
private extension JSONEncoder {static var pretty:JSONEncoder{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return e};static var sorted:JSONEncoder{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return e}}
public struct MCPTool: Codable, Identifiable, Sendable {
    public let name:String
    public let description:String?
    public let inputSchema:JSONValue
    public var id:String{name}
    public var ollama:JSONValue{.object(["type":.string("function"),"function":.object(["name":.string(name),"description":.string(description ?? name),"parameters":inputSchema])])}
}
public struct BrowserCall: Codable, Equatable, Sendable {
    public let name:String
    public let arguments:JSONValue
    public init(name:String,arguments:JSONValue){self.name=name;self.arguments=arguments}
    public var fingerprint:String{name+":"+arguments.canonical}
}
public struct BrowserRetryGate: Codable {
    public var rejections:[String:String]=[:]
    public var deniedTools:[String:String]? = nil
    public var consumedApprovalIDs:[UUID]? = nil
    public init(){}
    public mutating func authorizeExecution(_ call:BrowserCall,scopeID:String,requiresApproval:Bool,approval:BrowserApproval?,contextSHA256:String?=nil)throws {
        try check(call)
        guard !requiresApproval || approval != nil else{throw WorkbenchError.invalid("This proposal requires approval of the exact action before execution.")}
        if let approval {
            guard approval.scopeID==scopeID,approval.callSHA256==BrowserReceipt.hash(Data(call.fingerprint.utf8)) else{throw WorkbenchError.invalid("Approval does not match this exact action and scenario.")}
            guard approval.contextSHA256==contextSHA256 else{throw WorkbenchError.invalid("Observed page, objective or scope changed; review this action again.")}
            guard !(consumedApprovalIDs ?? []).contains(approval.id) else{throw WorkbenchError.invalid("This approval has already been used. Review a fresh action.")}
            consumedApprovalIDs=(consumedApprovalIDs ?? [])+[approval.id]
        }
    }
    public mutating func resetRejections(){rejections=[:];deniedTools=nil}
    public func check(_ call:BrowserCall)throws {if let reason=deniedTools?[call.name]{throw WorkbenchError.invalid("Tool permission remains denied: "+reason)};if let reason=rejections[call.fingerprint]{throw WorkbenchError.invalid("Repeated rejected request blocked: "+reason+". Inspect diagnostics and explicitly reset only after conditions change.")}}
    public mutating func reject(_ call:BrowserCall,reason:String){
        rejections[call.fingerprint]=reason
        let lower=reason.lowercased()
        if lower.contains("permission") || lower.contains("operator denied") {var denied=deniedTools ?? [:];denied[call.name]=reason;deniedTools=denied}
    }
}
public actor MCPConnection {
    private var process:OwnedMCPProcess?
    private var stoppingProcesses:[OwnedMCPProcess]=[]
    private var ownedSocketDirectory:URL?
    private var input:FileHandle?
    private var output:FileHandle?
    private var stderr:FileHandle?
    private var buffer=Data()
    private var nextID=0
    private var generation=0
    private var pending:[Int:CheckedContinuation<JSONValue,Error>]=[:]
    private var errors=""
    private var readerTask:Task<Void,Never>?
    private var errorReaderTask:Task<Void,Never>?
    public init(){}
    public static func localBrowserProfile(socketDirectory:URL)->String {
        let path=socketDirectory.path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        return "(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip \"localhost:*\"))(allow network-outbound (subpath \""+path+"\"))"
    }
    public func start(executable:URL,arguments:[String],directory:URL,localOnly:Bool) async throws {
        guard await stop() else { throw WorkbenchError.invalid("Previous MCP transport is still stopping.") };errors="";let stdin=Pipe();let stdout=Pipe();let err=Pipe()
        // Keep Playwright IPC in an owned short path: Unix socket paths have a small length limit.
        let socketDirectory=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("wmp-"+String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at:socketDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        ownedSocketDirectory=socketDirectory
        var environment=ProcessInfo.processInfo.environment;environment["TMPDIR"]=socketDirectory.path;environment["TMP"]=socketDirectory.path;environment["TEMP"]=socketDirectory.path
        let commandExecutable = localOnly ? URL(fileURLWithPath:"/usr/bin/sandbox-exec") : executable
        let commandArguments = localOnly ? ["-p",Self.localBrowserProfile(socketDirectory:socketDirectory),executable.path]+arguments : arguments
        input=stdin.fileHandleForWriting;output=stdout.fileHandleForReading;stderr=err.fileHandleForReading
        let outputHandle=stdout.fileHandleForReading;let errorHandle=err.fileHandleForReading;let readerGeneration=generation
        // A single ordered reader preserves JSON lines across large screenshot chunks.
        readerTask=Task { [weak self] in
            guard !Task.isCancelled else{return}
            for await data in Self.byteStream(outputHandle) {await self?.receive(data,generation:readerGeneration)}
            await self?.receive(Data(),generation:readerGeneration)
        }
        errorReaderTask=Task { [weak self] in
            guard !Task.isCancelled else{return}
            for await data in Self.byteStream(errorHandle) {await self?.receiveError(data,generation:readerGeneration)}
        }
        do {
            process = try OwnedMCPProcess(executable:commandExecutable,arguments:commandArguments,environment:environment,directory:directory,
                                          stdin:stdin.fileHandleForReading,stdout:stdout.fileHandleForWriting,stderr:err.fileHandleForWriting)
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            _ = try await request("initialize",params:.object(["protocolVersion":.string("2024-11-05"),"capabilities":.object([:]),"clientInfo":.object(["name":.string("Wampum"),"version":.string("0.1.0")])]))
            try write(.object(["jsonrpc":.string("2.0"),"method":.string("notifications/initialized")]))
        } catch {let detail=errors;if generation == readerGeneration {await stop()};throw WorkbenchError.invalid("Playwright MCP connection failed: \(error.localizedDescription)\n\(detail)")}
    }
    private final class ReaderCancellation: @unchecked Sendable {
        private let lock=NSLock()
        private var value=false
        func cancel(){lock.lock();value=true;lock.unlock()}
        var cancelled:Bool{lock.lock();defer{lock.unlock()};return value}
    }
    private nonisolated static func byteStream(_ handle:FileHandle)->AsyncStream<Data> {
        // The reader owns a duplicate. Closing a previous transport cannot make it
        // read a recycled descriptor belonging to a newly connected transport.
        let descriptor=dup(handle.fileDescriptor)
        return AsyncStream(bufferingPolicy:.bufferingOldest(128)) {continuation in
            guard descriptor >= 0 else {continuation.finish();return}
            let cancellation=ReaderCancellation()
            continuation.onTermination={_ in cancellation.cancel()}
            DispatchQueue(label:"Wampum.MCP.reader."+UUID().uuidString,qos:.userInitiated).async {
                defer{Darwin.close(descriptor);continuation.finish()}
                var bytes=[UInt8](repeating:0,count:65536)
                while !cancellation.cancelled {
                    var descriptorState=pollfd(fd:descriptor,events:Int16(POLLIN | POLLHUP),revents:0)
                    let ready=Darwin.poll(&descriptorState,1,100)
                    if ready<0 && errno==EINTR {continue}
                    if ready<0 {return}
                    if ready==0 {continue}
                    let count=Darwin.read(descriptor,&bytes,bytes.count)
                    if count<0 && errno==EINTR {continue}
                    if count<=0 {return}
                    switch continuation.yield(Data(bytes.prefix(count))) {
                    case .dropped, .terminated:return
                    case .enqueued:break
                    @unknown default:return
                    }
                }
            }
        }
    }
    @discardableResult
    public func stop() async -> Bool {
        _ = stopNow()
        for _ in 0..<250 {
            stoppingProcesses.removeAll{!$0.isRunning}
            if stoppingProcesses.isEmpty {return true}
            // Cleanup must finish even when the caller's task has been cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.02){continuation.resume()}
            }
        }
        stoppingProcesses.removeAll{!$0.isRunning}
        return stoppingProcesses.isEmpty
    }
    private func stopNow()->OwnedMCPProcess? {
        generation += 1
        readerTask?.cancel();errorReaderTask?.cancel();readerTask=nil;errorReaderTask=nil
        try? input?.close();try? output?.close();try? stderr?.close()
        let stoppedProcess=process;let socketDirectory=ownedSocketDirectory;ownedSocketDirectory=nil
        if let stoppedProcess,stoppedProcess.isRunning{
            stoppingProcesses.append(stoppedProcess)
            stoppedProcess.terminate()
        }
        Task.detached {
            for _ in 0..<250 {if stoppedProcess?.isRunning != true{break};try? await Task.sleep(nanoseconds:20_000_000)}
            if stoppedProcess?.isRunning != true,let socketDirectory{try? FileManager.default.removeItem(at:socketDirectory)}
        }
        process=nil;input=nil;output=nil;stderr=nil;buffer=Data()
        let abandoned=pending;pending=[:];for waiter in abandoned.values{waiter.resume(throwing:WorkbenchError.invalid("MCP disconnected."))}
        return stoppedProcess
    }
    public func ownedProcessIdentifier()->Int32? {process?.identifier}
    public func diagnostics()->String{errors}
    private func receiveError(_ data:Data,generation:Int?=nil){if let generation,generation != self.generation{return};if !data.isEmpty{errors=String((errors+String(decoding:data,as:UTF8.self)).suffix(16000))}}
    private func receive(_ data:Data,generation:Int){
        guard generation==self.generation else{return}
        if data.isEmpty {let abandoned=pending;pending=[:];for waiter in abandoned.values{waiter.resume(throwing:WorkbenchError.invalid("MCP server closed its output. "+errors))};return}
        buffer.append(data)
        guard buffer.count<=24_000_000 else{_ = stopNow();return}
        while let newline=buffer.firstIndex(of:10){let line=buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
            guard let value=try? JSONDecoder().decode(JSONValue.self,from:line) else{receiveError(line);continue}
            if case .number(let n)?=value["id"],let waiter=pending.removeValue(forKey:Int(n)) {
                if let error=value["error"] {waiter.resume(throwing:WorkbenchError.invalid(error.pretty))} else {waiter.resume(returning:value["result"] ?? .null)}
            } else if let id=value["id"],let method=value["method"]?.string {
                if method=="ping" {try? write(.object(["jsonrpc":.string("2.0"),"id":id,"result":.object([:])]))}
                else {try? write(.object(["jsonrpc":.string("2.0"),"id":id,"error":.object(["code":.number(-32601),"message":.string("Client method unavailable")])]))}
            }
        }
    }
    private func write(_ value:JSONValue)throws {guard let input else{throw WorkbenchError.invalid("MCP is disconnected.")};var data=try JSONEncoder().encode(value);data.append(10);try input.write(contentsOf:data)}
    private func expire(_ id:Int){pending.removeValue(forKey:id)?.resume(throwing:WorkbenchError.invalid("MCP request timed out. Inspect server diagnostics; no automatic retry."))}
    public func request(_ method:String,params:JSONValue = .object([:]),timeout:Double=35) async throws -> JSONValue {
        nextID+=1;let id=nextID
        return try await withCheckedThrowingContinuation {continuation in
            pending[id]=continuation
            do {try write(.object(["jsonrpc":.string("2.0"),"id":.number(Double(id)),"method":.string(method),"params":params]))}
            catch {pending.removeValue(forKey:id)?.resume(throwing:error);return}
            Task {try? await Task.sleep(nanoseconds:UInt64(timeout*1_000_000_000));self.expire(id)}
        }
    }
    public func tools() async throws -> [MCPTool] {let result=try await request("tools/list");return try JSONDecoder().decode([MCPTool].self,from:JSONEncoder().encode(result["tools"] ?? .array([])))}
    public func call(_ call:BrowserCall) async throws -> JSONValue {try await request("tools/call",params:.object(["name":.string(call.name),"arguments":call.arguments]))}
}
