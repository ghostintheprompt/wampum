import Foundation

public struct NetworkEvent: Codable, Identifiable {
    public let id: UUID
    public let at: Date
    public let component: String
    public let destination: String
    public let decision: String
    public let detail: String
}
public actor NetworkGuard {
    private let directory: URL?
    public init(directory: URL? = nil) { self.directory=directory }
    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme=="http", url.user==nil, url.password==nil, let host=url.host?.lowercased() else {return false}
        return ["127.0.0.1","localhost","::1","[::1]"].contains(host)
    }
    public func record(component:String,destination:String,decision:String,detail:String) throws {
        guard let directory else{return}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=directory.appendingPathComponent("network-events.jsonl")
        let event=NetworkEvent(id:UUID(),at:Date(),component:component,destination:destination,decision:decision,detail:detail)
        var data=try JSONEncoder().encode(event);data.append(10)
        if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        let handle=try FileHandle(forWritingTo:url);defer{try? handle.close()};try handle.seekToEnd();try handle.write(contentsOf:data)
    }
    public func authorize(_ url:URL,component:String,operation:String) throws {
        let allowed=Self.isLoopback(url)
        let destination="\(url.scheme ?? "unknown")://\(url.host ?? "unknown"):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        try record(component:component,destination:destination,decision:allowed ? "LOCAL_ALLOWED":"NONLOCAL_BLOCKED",detail:operation)
        guard allowed else{throw WorkbenchError.invalid("Network Guard blocked a nonlocal destination: \(destination)")}
    }
    public func recent() throws -> [NetworkEvent] {
        guard let directory else{return []};let url=directory.appendingPathComponent("network-events.jsonl")
        guard FileManager.default.fileExists(atPath:url.path) else{return []}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        let size=try handle.seekToEnd();try handle.seek(toOffset:size>131072 ? size-131072:0)
        let data=try handle.readToEnd() ?? Data();let lines=String(decoding:data,as:UTF8.self).split(separator:"\n")
        return lines.suffix(100).compactMap{try? JSONDecoder().decode(NetworkEvent.self,from:Data($0.utf8))}.reversed()
    }
}
public struct CommandPlan {
    public let executable: URL
    public let arguments: [String]
    public let networkDecision: String
    public static let loopbackProfile="(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip \"localhost:*\"))"
    public static func make(command:String,externalAllowed:Bool=false)throws->CommandPlan {
        guard !command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw WorkbenchError.invalid("Command required.")}
        if externalAllowed{return CommandPlan(executable:URL(fileURLWithPath:"/bin/zsh"),arguments:["-c",command],networkDecision:"EXTERNAL_ALLOWED_ONCE")}
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/sandbox-exec") else{throw WorkbenchError.invalid("Local command guard is unavailable. Command was not run.")}
        return CommandPlan(executable:URL(fileURLWithPath:"/usr/bin/sandbox-exec"),arguments:["-p",loopbackProfile,"/bin/zsh","-c",command],networkDecision:"DIRECT_SOCKETS_LOOPBACK_ONLY")
    }
    /// A direct owned-process invocation of an external tool binary (argv, no shell, no
    /// sandbox wrapping). Used for tools whose network cannot be meaningfully contained by
    /// wrapping the client process (e.g. the Docker client, whose daemon spawns containers);
    /// containment there is the scope gate, operator approval and receipt, not sandbox-exec.
    public static func ownedTool(executable:URL,arguments:[String])throws->CommandPlan {
        guard FileManager.default.isExecutableFile(atPath:executable.path) else{throw WorkbenchError.invalid("Tool executable not found: \(executable.path)")}
        for argument in arguments where argument.contains("\0"){throw WorkbenchError.invalid("Tool argument contains a null byte.")}
        return CommandPlan(executable:executable,arguments:arguments,networkDecision:"EXTERNAL_TOOL_DIRECT")
    }
}
