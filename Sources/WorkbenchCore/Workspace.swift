import Foundation
public enum WorkbenchError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public struct Workspace {
    public let root: URL
    public init(root: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw WorkbenchError.invalid("Choose an existing project folder.") }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }
    public func resolve(_ path: String, existing: Bool = true) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw WorkbenchError.invalid("Use a relative path inside the project.") }
        let target = root.appendingPathComponent(path).standardizedFileURL
        let resolved = target.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw WorkbenchError.invalid("Path leaves the selected project.") }
        if existing && !FileManager.default.fileExists(atPath: resolved.path) { throw WorkbenchError.invalid("File does not exist: \(path)") }
        return resolved
    }
    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw WorkbenchError.invalid("Open a regular UTF-8 text file under 1 MB.") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    public func files() throws -> [String] {
        let ignored: Set<String> = [".git", "node_modules", ".build", ".venv", "venv", "dist", ".next", "build", ".DS_Store"]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var output: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if ignored.contains(url.lastPathComponent) || values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory != true { output.append(String(url.path.dropFirst(root.path.count + 1))) }
            if output.count >= 2000 { break }
        }
        return output.sorted()
    }
    public func save(_ path: String, content: String, expected: String?, backupDirectory: URL) throws {
        let url = try resolve(path, existing: false)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            let current = try read(path)
            guard let expected = expected, current == expected else { throw WorkbenchError.invalid("File changed on disk. Reopen it before saving; your draft is preserved.") }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(current.utf8).write(to: backupDirectory.appendingPathComponent(UUID().uuidString + ".txt"), options: [.atomic])
        } else if expected != nil { throw WorkbenchError.invalid("File disappeared from disk. Reopen before saving.") }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw WorkbenchError.invalid("Parent folder does not exist.") }
        try Data(content.utf8).write(to: url, options: [.atomic])
    }
}
public struct ChatMessage: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var role: String
    public var content: String
    public var imagePaths: [String]? = nil
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public struct Session: Codable {
    public var project = ""
    public var file = ""
    public var draft = ""
    public var original: String? = nil
    public var notes = ""
    public var scope = ""
    public var prompt = ""
    public var model = ""
    public var context = 8192
    public var messages: [ChatMessage] = []
    public var lab: LabMemory? = nil
    public var images: [String]? = nil
    public var browserGoal: String? = nil
    public var browserURL: String? = nil
    public init() {}
}
public struct SessionStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        try data.write(to: directory.appendingPathComponent("session.json"), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("session.json").path)
    }
    public func load() throws -> Session {
        let url = directory.appendingPathComponent("session.json")
        return FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(Session.self, from: Data(contentsOf: url)) : Session()
    }
}
public struct ContextPacket {
    public var messages: [[String: String]]
    public let omitted: Int
    public let estimatedTokens: Int
    public static func build(system: String, history: [ChatMessage], context: Int, extraTokens: Int = 0) throws -> ContextPacket {
        guard [4096,8192,16384,32768].contains(context) else { throw WorkbenchError.invalid("Unsupported context profile.") }
        let budget = context - 1536
        func estimate(_ text: String) -> Int { (text.utf8.count + 2) / 3 + 12 }
        var groups: [[ChatMessage]] = []
        for message in history {
            if message.role == "user" || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(message)
        }
        var selected: [ChatMessage] = []
        guard extraTokens>=0 else{throw WorkbenchError.invalid("Invalid context reserve.")}
        var total = estimate(system)+extraTokens
        guard total <= budget else { throw WorkbenchError.invalid("Case notes/editor context exceeds this context profile. Shorten attached context first.") }
        for group in groups.reversed() {
            let cost = group.reduce(0) { $0 + estimate($1.content) }
            if total + cost > budget {
                if selected.isEmpty { throw WorkbenchError.invalid("Current prompt/checkpoint is too large for this profile. Shorten it or choose a larger context.") }
                break
            }
            selected = group + selected; total += cost
        }
        return ContextPacket(messages: [["role":"system", "content":system]] + selected.map { ["role":$0.role,"content":$0.content] }, omitted: history.count-selected.count, estimatedTokens: total)
    }
}
