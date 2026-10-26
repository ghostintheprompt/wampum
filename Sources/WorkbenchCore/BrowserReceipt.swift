import Foundation
import CryptoKit

public struct BrowserReceipt:Codable,Identifiable {
    public enum Execution:String,Codable {case notSent,inFlight,succeeded,reportedFailure,unknown}
    public enum Observation:String,Codable {case notRequested,pending,succeeded,failed}
    public let id:UUID
    public let controllerID:UUID?
    public let tool:String
    public let fingerprint:String
    public let startedAt:Date
    public var updatedAt:Date
    public var execution:Execution = .notSent
    public var refresh:Observation = .notRequested
    public var capture:Observation = .notRequested
    public var detail=""
    public var refreshError=""
    public var captureError=""
    public var captureFile:String?
    public var captureSHA256:String?
    public var storageError:String?
    public var provenance:BrowserProvenance?
    public var acknowledged=false
    public init(call:BrowserCall,controllerID:UUID?=nil){id=UUID();self.controllerID=controllerID;tool=call.name;fingerprint=Self.hash(Data(call.fingerprint.utf8));startedAt=Date();updatedAt=startedAt}
    public static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    public var summary:String {
        switch execution {
        case .notSent:return "Not sent: "+detail
        case .inFlight:return "Sent; tool result pending. Do not repeat."
        case .unknown:return "Action outcome unknown. Do not repeat until the page is checked. "+detail
        case .reportedFailure:return "Tool reported an error; side effects are not independently verified. "+detail
        case .succeeded:
            if let storageError{return "Tool succeeded; evidence storage incomplete. "+storageError}
            if refresh == .failed{return "Tool succeeded; page refresh failed. Do not repeat the action to repair the refresh."}
            if capture == .failed{return "Tool succeeded; page refresh \(refresh.rawValue); screenshot failed."}
            if refresh == .pending || capture == .pending{return "Tool succeeded; observation still pending."}
            return "Tool succeeded; page refresh \(refresh.rawValue); screenshot \(capture.rawValue). Target outcome still requires evidence."
        }
    }
}
public struct BrowserReceiptStore {
    public let directory:URL
    public init(root:URL,scope:String)throws {
        guard scope.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil else{throw WorkbenchError.invalid("Invalid receipt scope.")}
        directory=root.appendingPathComponent("browser-receipts/"+scope)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    public func save(_ receipts:[BrowserReceipt])throws {
        let file=directory.appendingPathComponent("recent.json")
        try JSONEncoder().encode(Array(receipts.suffix(100))).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public func load()throws->[BrowserReceipt] {
        let file=directory.appendingPathComponent("recent.json")
        guard FileManager.default.fileExists(atPath:file.path) else{return []}
        let data=try Data(contentsOf:file);guard data.count<=1_048_576 else{throw WorkbenchError.invalid("Receipt history is too large; preserve and inspect it before continuing.")}
        return try JSONDecoder().decode([BrowserReceipt].self,from:data)
    }
    public func saveCapture(_ data:Data,id:UUID)throws->(String,String) {
        guard data.count<=8_000_000 else{throw WorkbenchError.invalid("Capture exceeds evidence storage limit.")}
        let file=directory.appendingPathComponent(id.uuidString+".jpg")
        try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        return(file.path,BrowserReceipt.hash(data))
    }
}
