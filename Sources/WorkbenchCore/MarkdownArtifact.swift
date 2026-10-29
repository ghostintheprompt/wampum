import Foundation

public enum MarkdownArtifact {
    // A complete outer fence must have its own closing line. Inner shorter fences stay intact.
    public static func replacement(in text: String) -> String? {
        let lines=text.components(separatedBy:"\n")
        guard let start=lines.firstIndex(where: { $0.hasPrefix("```") || $0.hasPrefix("~~~") }) else {return nil}
        let opening=lines[start]
        guard let marker=opening.first else {return nil}
        let count=opening.prefix(while: {$0 == marker}).count
        guard count >= 3 else {return nil}
        guard let end=lines.indices.dropFirst(start+1).first(where: {
            let line=lines[$0].trimmingCharacters(in:.whitespacesAndNewlines)
            return line.count >= count && line.allSatisfy {$0 == marker}
        }) else {return nil}
        return lines[(start+1)..<end].joined(separator:"\n") + (end > start+1 ? "\n" : "")
    }
    public static func hasUnclosedFence(_ text: String) -> Bool {
        var opened: (Character,Int)?
        for raw in text.components(separatedBy:"\n") {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            guard let marker=line.first, marker == "`" || marker == "~" else {continue}
            let count=line.prefix(while: {$0 == marker}).count
            guard count >= 3 else {continue}
            if let current=opened {
                if marker == current.0, count >= current.1, line.allSatisfy({$0 == marker}) {opened=nil}
            } else {opened=(marker,count)}
        }
        return opened != nil
    }
    public static func transcript(_ messages: [ChatMessage], assistantOnly: Bool = false) -> String {
        let selected=messages.filter { !assistantOnly || $0.role == "assistant" }
        var output=assistantOnly ? "# Wampum assistant replies\n" : "# Wampum conversation\n"
        output += "\nExported locally. Original message bodies are preserved in order. A model stop does not verify its claims or completeness.\n"
        for (index,message) in selected.enumerated() {
            output += "\n\n---\n\n## Message \(index+1): \(message.role)\n\n"
            if message.stopReason == "length" {output += "> INCOMPLETE: output token limit reached.\n\n"}
            if let reason=message.stopReason {output += "Stop reason: \(reason)\n\n"}
            if hasUnclosedFence(message.content) {
                // Retain malformed historical output verbatim without swallowing later messages.
                let longest=message.content.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence=String(repeating:"`",count:max(4,longest+1))
                output += "> Original response has an unclosed code fence; retained verbatim below.\n\n" + fence + "markdown\n" + message.content + "\n" + fence
            } else {output += message.content}
            if let paths=message.imagePaths, !paths.isEmpty {
                output += "\n\nLocal attachment references (images are not embedded):\n" + paths.map { "- " + $0 }.joined(separator:"\n")
            }
        }
        return output+"\n"
    }
    public static func export(_ response: String, to url: URL) throws {
        // Preserve all response bytes, including nested code fences and prose.
        let expected=Data(response.utf8)
        try expected.write(to:url,options:.atomic)
        guard try Data(contentsOf:url) == expected else {
            throw WorkbenchError.invalid("Export read-back did not match the complete response. Check the destination file.")
        }
    }
}
