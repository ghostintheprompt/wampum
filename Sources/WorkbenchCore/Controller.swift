import Foundation

public struct ControllerRequest:Codable {
    public let id:UUID
    public let clientID:String
    public let clientName:String
    public let token:String
    public let tool:String
    public let arguments:JSONValue
    public let createdAt:Date
    public init(id:UUID=UUID(),clientID:String,clientName:String,token:String,tool:String,arguments:JSONValue,createdAt:Date=Date()){self.id=id;self.clientID=clientID;self.clientName=clientName;self.token=token;self.tool=tool;self.arguments=arguments;self.createdAt=createdAt}
}
public struct ControllerAccess:Codable {public let token:String;public init(token:String){self.token=token}}
public struct ControllerLease {
    public let token:String
    public let scenario:String
    public let context:String
    public let expiresAt:Date
    public var owner:String?
    public var calls=0
    public var actions=0
    public var sharedBytes=0
    public let maxCalls:Int
    public let maxActions:Int
    public let maxBytes:Int
    public init(token:String,scenario:String,context:String,now:Date=Date(),seconds:Double=900,maxCalls:Int=120,maxActions:Int=20,maxBytes:Int=262144){self.token=token;self.scenario=scenario;self.context=context;self.expiresAt=now.addingTimeInterval(seconds);self.maxCalls=maxCalls;self.maxActions=maxActions;self.maxBytes=maxBytes}
    public mutating func authorize(_ request:ControllerRequest,scenario:String,now:Date=Date())throws {
        guard request.token==token else{throw WorkbenchError.invalid("Controller capability is invalid. Enable a new connection in Wampum.")}
        guard scenario==self.scenario else{throw WorkbenchError.invalid("Scenario changed. Controller connection revoked.")}
        guard now<expiresAt,now.timeIntervalSince(request.createdAt)<30,request.createdAt.timeIntervalSince(now)<5 else{throw WorkbenchError.invalid("Controller connection or request expired.")}
        guard owner==nil || owner==request.clientID else{throw WorkbenchError.invalid("Another controller owns this connection. Revoke it before changing controllers.")}
        guard request.tool=="wampum_stop" || calls<maxCalls else{throw WorkbenchError.invalid("Controller call budget reached. Revoke and review before enabling another connection.")}
        owner=request.clientID;calls+=1
    }
    public mutating func reserveAction()throws{guard actions<maxActions else{throw WorkbenchError.invalid("Controller action budget reached.")};actions+=1}
    public mutating func account(_ value:JSONValue)throws {let count=value.canonical.utf8.count;guard sharedBytes+count<=maxBytes else{throw WorkbenchError.invalid("Controller sharing budget reached.")};sharedBytes+=count}
}
public struct ControllerMailbox {
    public let directory:URL
    public init(stateDirectory:URL){directory=stateDirectory.appendingPathComponent("controller")}
    public var accessURL:URL{directory.appendingPathComponent("access.json")}
    public func prepare()throws{
        for path in [directory,directory.appendingPathComponent("requests"),directory.appendingPathComponent("responses")] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    }
    private func write<T:Encodable>(_ value:T,to url:URL)throws{try JSONEncoder().encode(value).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    public func grant(token:String)throws{try prepare();try write(ControllerAccess(token:token),to:accessURL)}
    public func revoke()throws{if FileManager.default.fileExists(atPath:accessURL.path){try FileManager.default.removeItem(at:accessURL)}}
    public func access()throws->ControllerAccess {try JSONDecoder().decode(ControllerAccess.self,from:Data(contentsOf:accessURL))}
    public func enqueue(_ request:ControllerRequest)throws {try prepare();let data=try JSONEncoder().encode(request);guard data.count<=65536 else{throw WorkbenchError.invalid("Controller request exceeds 64 KB.")};try write(request,to:directory.appendingPathComponent("requests/"+request.id.uuidString+".json"))}
    public func requests()throws->[ControllerRequest] {
        try prepare()
        let paths=try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("requests"),includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        var result:[ControllerRequest]=[]
        for path in paths.prefix(20) {
            guard UUID(uuidString:path.deletingPathExtension().lastPathComponent) != nil else{continue}
            let properties=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard properties.isRegularFile==true,properties.isSymbolicLink != true,(properties.fileSize ?? Int.max)<=65536 else{continue}
            let request=try JSONDecoder().decode(ControllerRequest.self,from:Data(contentsOf:path))
            guard request.id.uuidString==path.deletingPathExtension().lastPathComponent else{throw WorkbenchError.invalid("Controller request ID mismatch.")};result.append(request)
        }
        return result
    }
    public func respond(_ request:ControllerRequest,value:JSONValue)throws {try write(value,to:directory.appendingPathComponent("responses/"+request.id.uuidString+".json"));try FileManager.default.removeItem(at:directory.appendingPathComponent("requests/"+request.id.uuidString+".json"))}
    public func response(_ id:UUID)throws->JSONValue? {
        let path=directory.appendingPathComponent("responses/"+id.uuidString+".json")
        guard FileManager.default.fileExists(atPath:path.path) else{return nil}
        let data=try Data(contentsOf:path);guard data.count<=300000 else{throw WorkbenchError.invalid("Controller response too large.")}
        let value=try JSONDecoder().decode(JSONValue.self,from:data);try FileManager.default.removeItem(at:path);return value
    }
}
public enum ControllerTools {
    public static var definitions:[JSONValue] {
        func tool(_ name:String,_ description:String,_ properties:[String:JSONValue]=[:],_ required:[String]=[])->JSONValue {
            .object(["name":.string(name),"description":.string(description),"inputSchema":.object(["type":.string("object"),"properties":.object(properties),"required":.array(required.map{.string($0)}),"additionalProperties":.bool(false)])])
        }
        let text:JSONValue = .object(["type":.string("string"),"maxLength":.number(8000)])
        return [
            tool("wampum_status","Read controller budgets and reviewed action/submission status. Does not expose unreviewed page content."),
            tool("wampum_context","Read only the operator-approved frozen scenario handoff."),
            tool("wampum_propose_browser_action","Propose one browser action for native operator review. This NEVER executes it. Poll status after review; do not repeat pending or denied calls.",["tool":text,"arguments":.object(["type":.string("object")]),"reason":text],["tool","arguments","reason"]),
            tool("wampum_request_observation","Request operator review of the current page snapshot for sharing. Returns a ticket; it does not return page content."),
            tool("wampum_read_observation","Read a specific approved observation ticket. Pending/denied observations contain no page content.",["ticket":text],["ticket"]),
            tool("wampum_submit_checkpoint","Submit a proposed checkpoint/evidence note for operator review. Does not edit lab files or assert a verified outcome.",["text":text],["text"]),
            tool("wampum_stop","Stop the browser workflow and revoke this controller connection.")
        ]
    }
}
