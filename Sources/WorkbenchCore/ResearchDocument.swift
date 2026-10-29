import Foundation
import CryptoKit

public struct ResearchChapter: Codable {
    public var title:String
    public var source:String
    public var url:String
    public var exerciseBrief:String?
    public var codeProgram:String?
    public var codeAttribution:String?
    public var proseFacts:String?
    public init(title:String,source:String,url:String,exerciseBrief:String?=nil,codeProgram:String?=nil,codeAttribution:String?=nil,proseFacts:String?=nil){self.title=title;self.source=source;self.url=url;self.exerciseBrief=exerciseBrief;self.codeProgram=codeProgram;self.codeAttribution=codeAttribution;self.proseFacts=proseFacts}
    public func validateFrozenProgram(_ renderedCode:String)throws {
        if let program=codeProgram {guard renderedCode==program+"\n" else{throw WorkbenchError.invalid("Frozen implementation changed; repair prose only.")}}
    }
}
public struct ResearchManifest: Codable {
    public var title:String
    public var model:String
    public var requirements:[String]
    public var chapters:[ResearchChapter]
    public var originalPrompts:[String]?
    public var workflowVersion:String?
}
public struct ResearchSection: Codable {
    public var title:String
    public var sourceHash:String
    public var body:String
    public var stopReason:String
    public var outputTokens:Int
    public var checkLog:String
    public var checked:Bool
    public var bodyHash:String?
    public init(title:String,sourceHash:String,body:String,stopReason:String,outputTokens:Int,checkLog:String,checked:Bool){self.title=title;self.sourceHash=sourceHash;self.body=body;self.stopReason=stopReason;self.outputTokens=outputTokens;self.checkLog=checkLog;self.checked=checked;self.bodyHash=ResearchDocument.digest(body)}
}
public enum ResearchDocument {
    public static func shellQuote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    public static func digest(_ text:String)->String{SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    @discardableResult public static func validateRepairShape(_ body:String)throws->String {
        guard !MarkdownArtifact.hasUnclosedFence(body) else{throw WorkbenchError.invalid("Unclosed Markdown fence.")}
        let expression=try NSRegularExpression(pattern:#"(?ms)^(`{3,})python[ \t]*\n(.*?)^\1[ \t]*$"#)
        let range=NSRange(body.startIndex...,in:body),matches=expression.matches(in:body,range:range)
        guard matches.count==1,let codeRange=Range(matches[0].range(at:2),in:body) else{throw WorkbenchError.invalid("Provide exactly one complete Python block containing both examples, defense and unittest cases.")}
        let outside=NSMutableString(string:body);outside.replaceCharacters(in:matches[0].range,with:"")
        let prose=outside as String,proseRange=NSRange(prose.startIndex...,in:prose)
        for name in ["Mechanism","Examples","Defense","Verification"] {
            let heading=try NSRegularExpression(pattern:"(?m)^## "+name+"[ \t\r]*$")
            guard heading.numberOfMatches(in:prose,range:proseRange)==1 else{throw WorkbenchError.invalid("Keep exactly one required heading outside the program: "+name)}
        }
        let other=try NSRegularExpression(pattern:#"(?m)^[ \t]*(?:`{3,}|~{3,})"#)
        guard other.numberOfMatches(in:prose,range:proseRange)==0 else{throw WorkbenchError.invalid("Extra unchecked code blocks are not accepted.")}
        return String(body[codeRange])
    }
    public static func validate(_ body:String,reason:String?)throws->String{
        guard reason == "stop" else{throw WorkbenchError.invalid("Section did not end naturally: \(reason ?? "unknown").")}
        guard body.utf8.count>=1800 else{throw WorkbenchError.invalid("Section is too short for the requested complete mechanism, two examples and tested defense.")}
        let code=try validateRepairShape(body)
        let forbidden=["[RESTRICTED]","[FLAG]","TODO","TBD","INSERT_HERE","YOUR_API_KEY","100% success","SANDBOX VALIDATED"]
        guard !forbidden.contains(where:{body.localizedCaseInsensitiveContains($0)}) else{throw WorkbenchError.invalid("Unfilled placeholder or unsupported success claim.")}
        guard code.contains("unittest"),code.components(separatedBy:"def test_").count>=4 else{throw WorkbenchError.invalid("At least three actual unittest methods are required, including a negative control.")}
        return code
    }
    public static func verifyReceipt(_ log:String,code:String)throws {
        guard let line=log.components(separatedBy:"\n").last(where:{$0.hasPrefix("VERIFIED_RECEIPT ")}),let data=String(line.dropFirst("VERIFIED_RECEIPT ".count)).data(using:.utf8),let receipt=try JSONSerialization.jsonObject(with:data) as? [String:Any],receipt["codeSHA256"] as? String == digest(code),(receipt["tests"] as? Int ?? 0)>=3,receipt["failures"] as? Int == 0,receipt["errors"] as? Int == 0,receipt["skipped"] as? Int == 0 else {throw WorkbenchError.invalid("Actual test receipt is missing or does not match the current code.")}
    }
    public static func assemble(title:String,chapters:[ResearchChapter],sections:[ResearchSection])throws->String{
        guard !chapters.isEmpty,Set(chapters.map(\.title)).count==chapters.count,sections.count==chapters.count else{throw WorkbenchError.invalid("Requested chapters are missing; final document withheld.")}
        var text="# "+title+"\n\nLocal research companion. The examples use owned synthetic fixtures. Model text is not evidence of external exploitation. Each included program has a recorded local check.\n"
        for (chapter,section) in zip(chapters,sections) {
            guard section.checked,section.title==chapter.title,section.sourceHash==digest(chapter.source),section.bodyHash==digest(section.body) else{throw WorkbenchError.invalid("Unverified or stale section; final document withheld: \(chapter.title).")}
            let code=try validate(section.body,reason:section.stopReason)
            try chapter.validateFrozenProgram(code)
            try verifyReceipt(section.checkLog,code:code)
            text+="\n\n# "+chapter.title+"\n\nReference: "+chapter.url+"\n\n"+section.body+"\n\n### Actual local check receipt\n\nSource SHA-256: `"+section.sourceHash+"`\n\n"
            let fence=String(repeating:"`",count:max(4,(section.checkLog.split(whereSeparator:{$0 != "`"}).map(\.count).max() ?? 0)+1))
            text+=fence+"text\n"+section.checkLog+"\n"+fence+"\n"
        }
        return text
    }
}

public struct ResearchCandidate: Codable {
    public var id:String
    public var chapter:Int
    public var title:String
    public var sourceHash:String
    public var manifestHash:String
    public var body:String
    public var stopReason:String
    public var outputTokens:Int
    public var codeFile:String
    public var codeHash:String
    public var attempt:Int
    public var state:String
    public var failure:String
    public init(chapter:Int,title:String,sourceHash:String,manifestHash:String,body:String,stopReason:String,outputTokens:Int,codeFile:String,codeHash:String,attempt:Int,state:String="pending",failure:String="") {
        self.id=UUID().uuidString;self.chapter=chapter;self.title=title;self.sourceHash=sourceHash;self.manifestHash=manifestHash;self.body=body;self.stopReason=stopReason;self.outputTokens=outputTokens;self.codeFile=codeFile;self.codeHash=codeHash;self.attempt=attempt;self.state=state;self.failure=failure
    }
    public func reviewedCode(work:URL)throws->String {
        let manifestData=try Data(contentsOf:work.appendingPathComponent("manifest.json"))
        guard ResearchDocument.digest(String(decoding:manifestData,as:UTF8.self))==manifestHash else{throw WorkbenchError.invalid("Document manifest changed after generation.")}
        let manifest=try JSONDecoder().decode(ResearchManifest.self,from:manifestData)
        guard chapter>=0,chapter<manifest.chapters.count,manifest.chapters[chapter].title==title,ResearchDocument.digest(manifest.chapters[chapter].source)==sourceHash else{throw WorkbenchError.invalid("Candidate does not match the current source chapter.")}
        let code=try Workspace(root:work).read(codeFile)
        let bodyCode=try ResearchDocument.validate(body,reason:stopReason)
        try manifest.chapters[chapter].validateFrozenProgram(bodyCode)
        guard code==bodyCode,ResearchDocument.digest(code)==codeHash else{throw WorkbenchError.invalid("Generated program changed. A fresh review is required.")}
        return code
    }
}
public struct ResearchApproval: Codable {
    public var candidateID:String
    public var codeHash:String
    public var sourceHash:String
    public var manifestHash:String
    public var approvedAt:Date
    public var bodyHash:String?
    public init(_ candidate:ResearchCandidate){candidateID=candidate.id;codeHash=candidate.codeHash;sourceHash=candidate.sourceHash;manifestHash=candidate.manifestHash;approvedAt=Date();bodyHash=ResearchDocument.digest(candidate.body)}
    public func matches(_ candidate:ResearchCandidate)->Bool {candidateID==candidate.id && codeHash==candidate.codeHash && sourceHash==candidate.sourceHash && manifestHash==candidate.manifestHash && bodyHash==ResearchDocument.digest(candidate.body)}
}

public struct ResearchGeneratedSection:Decodable {
    public var mechanism:String;public var examples:String;public var defense:String;public var verification:String;public var python:String
    public var markdown:String {
        let longest=python.split(whereSeparator:{$0 != "`"}).map(\.count).max() ?? 0
        let fence=String(repeating:"`",count:max(3,longest+1))
        return "## Mechanism\n\n"+mechanism+"\n\n## Examples\n\n"+examples+"\n\n"+fence+"python\n"+python+"\n"+fence+"\n\n## Defense\n\n"+defense+"\n\n## Verification\n\n"+verification
    }
    public static var schema:Data {
        let names=["mechanism","examples","defense","verification","python"]
        let properties=Dictionary(uniqueKeysWithValues:names.map{($0,["type":"string"])})
        return try! JSONSerialization.data(withJSONObject:["type":"object","properties":properties,"required":names,"additionalProperties":false])
    }
}

public enum ResearchProseSection {
    public static func validate(_ fields:[String:Any])throws {
        for name in ["mechanism","examples","defense","verification"] {
            guard let value=fields[name] as? String else{throw WorkbenchError.invalid("Missing prose field: "+name)}
            let text=value.trimmingCharacters(in:.whitespacesAndNewlines)
            guard text.utf8.count>=80,let last=text.last,".!?".contains(last) else{throw WorkbenchError.invalid("Incomplete prose field: "+name+". Write substantive complete sentences, not a fragment or placeholder.")}
            let codeLine=try NSRegularExpression(pattern:#"(?m)^\s*(?:import [A-Za-z_]|from [A-Za-z_][A-Za-z0-9_.]* import |(?:async )?def [A-Za-z_]|class [A-Za-z_]|@[A-Za-z_])"#)
            guard codeLine.numberOfMatches(in:text,range:NSRange(text.startIndex...,in:text))==0 else{throw WorkbenchError.invalid("Code found in prose field: "+name+". Put all executable examples and tests in the checked Python program.")}

        }
    }
    public static var schema:Data {
        let names=["mechanism","examples","defense","verification"]
        let properties=Dictionary(uniqueKeysWithValues:names.map{($0,["type":"string"])})
        return try! JSONSerialization.data(withJSONObject:["type":"object","properties":properties,"required":names,"additionalProperties":false])
    }
}
