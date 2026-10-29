import Foundation

public struct ResearchRepairPatch: Decodable {
    public struct Edit: Decodable { public let old:String; public let new:String }
    public let edits:[Edit]
    public func applying(to source:String,expectedHash:String)throws->String {
        guard ResearchDocument.digest(source)==expectedHash else{throw WorkbenchError.invalid("Repair source changed; patch withheld.")}
        guard !edits.isEmpty,edits.count<=32 else{throw WorkbenchError.invalid("Expected 1–32 exact edits.")}
        var replacements:[(Range<String.Index>,String)]=[]
        for edit in edits {
            guard !edit.old.isEmpty,edit.old != edit.new,let range=source.range(of:edit.old),source.range(of:edit.old,range:range.upperBound..<source.endIndex)==nil else{throw WorkbenchError.invalid("Repair target must match exactly once in the original draft.")}
            guard !replacements.contains(where:{$0.0.overlaps(range)}) else{throw WorkbenchError.invalid("Repair edits overlap; patch withheld.")}
            replacements.append((range,edit.new))
        }
        var result=source
        for (range,text) in replacements.sorted(by:{$0.0.lowerBound>$1.0.lowerBound}) { result.replaceSubrange(range,with:text) }
        guard result.utf8.count<=2_097_152 else{throw WorkbenchError.invalid("Repaired draft exceeds 2 MB.")}
        return result
    }
    public static func rejectionFeedback(previous:String,current:String,draftUnchanged:Bool)->String {
        draftUnchanged ? previous+"\nREJECTED REPAIR; ORIGINAL DRAFT UNCHANGED: "+current : current
    }
    public static var schema:Data {
        try! JSONSerialization.data(withJSONObject:["type":"object","properties":["edits":["type":"array","items":["type":"object","properties":["old":["type":"string"],"new":["type":"string"]],"required":["old","new"],"additionalProperties":false]]],"required":["edits"],"additionalProperties":false])
    }
}
