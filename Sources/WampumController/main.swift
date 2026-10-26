import Foundation
import WorkbenchCore

let args=CommandLine.arguments
let state:URL
if let index=args.firstIndex(of:"--state-dir"),args.indices.contains(index+1){state=URL(fileURLWithPath:args[index+1])}
else{state=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Wampum")}
let mailbox=ControllerMailbox(stateDirectory:state)
let clientID=UUID().uuidString
var clientName="MCP controller"
var capability:String?
func send(_ id:JSONValue,_ result:JSONValue,error:Bool=false) {
    let response:JSONValue = .object(["jsonrpc":.string("2.0"),"id":id,error ? "error":"result":result])
    if let data=try? JSONEncoder().encode(response){FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))}
}
func toolReply(_ text:String,isError:Bool=false)->JSONValue{.object(["content":.array([.object(["type":.string("text"),"text":.string(text)])]),"isError":.bool(isError)])}
while let line=readLine() {
    guard line.utf8.count<=65536,let data=line.data(using:.utf8),let input=try? JSONDecoder().decode(JSONValue.self,from:data) else{continue}
    guard let id=input["id"] else{continue}
    switch input["method"]?.string {
    case "initialize":
        clientName=String((input["params"]?["clientInfo"]?["name"]?.string ?? "MCP controller").prefix(80))
        send(id,.object(["protocolVersion":.string("2024-11-05"),"capabilities":.object(["tools":.object([:])]),"serverInfo":.object(["name":.string("Wampum"),"version":.string("0.2.0")])]))
    case "ping":send(id,.object([:]))
    case "tools/list":send(id,.object(["tools":.array(ControllerTools.definitions)]))
    case "tools/call":
        do {
            guard let name=input["params"]?["name"]?.string,ControllerTools.definitions.contains(where:{$0["name"]?.string==name}) else{throw WorkbenchError.invalid("Unknown Wampum tool.")}
            if capability==nil {capability=try mailbox.access().token}
            let request=ControllerRequest(clientID:clientID,clientName:clientName,token:capability!,tool:name,arguments:input["params"]?["arguments"] ?? .object([:]))
            try mailbox.enqueue(request)
            let deadline=Date().addingTimeInterval(10)
            var result:JSONValue?
            repeat {result=try mailbox.response(request.id);if result != nil{break};Thread.sleep(forTimeInterval:0.1)}while Date()<deadline
            guard let result else{throw WorkbenchError.invalid("Wampum did not acknowledge the request. Open the app and check Controller. No action is automatically retried.")}
            send(id,toolReply(result.pretty,isError:result["error"] != nil))
        }catch{send(id,toolReply("Controller unavailable: "+error.localizedDescription,isError:true))}
    default:send(id,.object(["code":.number(-32601),"message":.string("Method unavailable")]),error:true)
    }
}
