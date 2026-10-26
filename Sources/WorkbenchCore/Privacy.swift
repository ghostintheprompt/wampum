import Foundation

public struct MaskingResult {
    public let text: String
    public let replacements: Int
    public init(text:String,replacements:Int){self.text=text;self.replacements=replacements}
}
public struct ContentMasker {
    public let aliases: [(String,String)]
    public let detectSecrets: Bool
    public init(rules:String="",detectSecrets:Bool=true)throws {
        var parsed:[(String,String)]=[]
        for line in rules.split(separator:"\n") {
            if line.trimmingCharacters(in:.whitespaces).isEmpty{continue}
            guard let separator=line.range(of:"=>") else{throw WorkbenchError.invalid("Use one exact value => alias per line.")}
            let source=String(line[..<separator.lowerBound]).trimmingCharacters(in:.whitespaces)
            let replacement=String(line[separator.upperBound...]).trimmingCharacters(in:.whitespaces)
            guard !source.isEmpty,!replacement.isEmpty else{throw WorkbenchError.invalid("Both the exact value and its alias are required.")}
            if parsed.contains(where:{$0.0==source}){throw WorkbenchError.invalid("Duplicate masking source: remove the duplicate rule.")}
            parsed.append((source,replacement))
        }
        self.aliases=parsed.sorted{$0.0.count > $1.0.count};self.detectSecrets=detectSecrets
    }
    public func mask(_ input:String)->MaskingResult {
        var text=input;var count=0
        if !aliases.isEmpty {
            let lookup=Dictionary(uniqueKeysWithValues:aliases)
            let pattern=aliases.map{NSRegularExpression.escapedPattern(for:$0.0)}.joined(separator:"|")
            if let expression=try? NSRegularExpression(pattern:pattern){
                let matches=expression.matches(in:input,range:NSRange(input.startIndex...,in:input))
                for match in matches.reversed(){if let range=Range(match.range,in:text),let replacement=lookup[String(text[range])]{text.replaceSubrange(range,with:replacement);count+=1}}
            }
        }
        if detectSecrets {
            let patterns=[#"(?i)\bBearer[ \t]+[A-Za-z0-9._~+/=-]{8,}"#,
                          #"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|AKIA[A-Z0-9]{16})\b"#,
                          #"(?i)\b(?:api[_-]?key|password|secret|access[_-]?token)[ \t]*[=:][ \t]*[\"']?[^\s\"',;]{6,}[\"']?"#,
                          #"(?s)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#]
            for pattern in patterns {
                guard let expression=try? NSRegularExpression(pattern:pattern) else{continue}
                let matches=expression.matches(in:text,range:NSRange(text.startIndex...,in:text))
                for match in matches.reversed(){if let range=Range(match.range,in:text){text.replaceSubrange(range,with:"[SECRET_MASKED]");count+=1}}
            }
        }
        return MaskingResult(text:text,replacements:count)
    }
}
public struct PrivacySettings:Codable {
    public var maskModelRequests=true
    public var maskExternalURLs=true
    public var detectSecrets=true
    public var aliasRules=""
    public var proxyURL=""
    public init(){}
    enum CodingKeys:String,CodingKey{case maskModelRequests,maskExternalURLs,detectSecrets,aliasRules,proxyURL}
    public init(from decoder:Decoder)throws{
        let c=try decoder.container(keyedBy:CodingKeys.self)
        maskModelRequests=try c.decodeIfPresent(Bool.self,forKey:.maskModelRequests) ?? true
        maskExternalURLs=try c.decodeIfPresent(Bool.self,forKey:.maskExternalURLs) ?? true
        detectSecrets=try c.decodeIfPresent(Bool.self,forKey:.detectSecrets) ?? true
        aliasRules=try c.decodeIfPresent(String.self,forKey:.aliasRules) ?? ""
        proxyURL=try c.decodeIfPresent(String.self,forKey:.proxyURL) ?? ""
    }
}
public struct PrivacyStore {
    public let directory:URL
    public init(directory:URL){self.directory=directory}
    public func load()throws->PrivacySettings {
        let file=directory.appendingPathComponent("privacy.json")
        return FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(PrivacySettings.self,from:Data(contentsOf:file)):PrivacySettings()
    }
    public func save(_ settings:PrivacySettings)throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent("privacy.json");try JSONEncoder().encode(settings).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
