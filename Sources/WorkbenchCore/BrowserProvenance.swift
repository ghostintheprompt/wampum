import Foundation

public struct BrowserApproval:Codable {
    public let id:UUID
    public let approvedAt:Date
    public let kind:String
    public let scopeID:String
    public let callSHA256:String
    public let contextSHA256:String?
    public init(call:BrowserCall,scopeID:String,kind:String="operator-reviewed-exact-call",contextSHA256:String?=nil) {
        id=UUID();approvedAt=Date();self.kind=kind;self.scopeID=scopeID;self.contextSHA256=contextSHA256;callSHA256=BrowserReceipt.hash(Data(call.fingerprint.utf8))
    }
}
public struct BrowserProvenance:Codable {
    public let schemaVersion:String
    public let scopeID:String
    public let callSHA256:String
    public let proposalSource:String
    public let pageSHA256:String?
    public let reviewedRequestSHA256:String?
    public let scopeSHA256:String?
    public let notesSHA256:String?
    public let goalSHA256:String
    public let approval:BrowserApproval?
    public init(call:BrowserCall,scopeID:String,proposalSource:String,page:String?,reviewedRequestSHA256:String?,scope:String?,notes:String?,goal:String,approval:BrowserApproval?) {
        schemaVersion="wampum-browser-provenance/v1";self.scopeID=scopeID;self.proposalSource=proposalSource
        callSHA256=BrowserReceipt.hash(Data(call.fingerprint.utf8));pageSHA256=page.map{BrowserReceipt.hash(Data($0.utf8))}
        self.reviewedRequestSHA256=reviewedRequestSHA256;scopeSHA256=scope.map{BrowserReceipt.hash(Data($0.utf8))};notesSHA256=notes.map{BrowserReceipt.hash(Data($0.utf8))};goalSHA256=BrowserReceipt.hash(Data(goal.utf8));self.approval=approval
    }
}
