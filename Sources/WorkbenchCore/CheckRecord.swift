import Foundation

public struct CheckRecord: Codable {
    public enum State: String, Codable { case running, completed, stopped, interrupted, launchFailed }
    public let id: UUID
    public let project: String
    public let command: String
    public let started: Date
    public var state: State
    public var exitCode: Int32?
    public var logName: String { "run-\(id.uuidString).log" }
    public init(project: String, command: String) {
        id=UUID();self.project=project;self.command=command;started=Date();state = .running
    }
}
public struct CheckRecordStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("last-check.json") }
    public init(directory: URL) { self.directory=directory }
    public func load() throws -> CheckRecord? {
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        guard (try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])).isSymbolicLink != true,
              (try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 131072 else { throw WorkbenchError.invalid("Check record is not a bounded regular record.") }
        return try JSONDecoder().decode(CheckRecord.self,from:Data(contentsOf:file))
    }
    public func save(_ record:CheckRecord) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(record)
        guard data.count <= 131072 else {throw WorkbenchError.invalid("Check record exceeds 128 KB.")}
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public func output(_ record:CheckRecord) throws -> String {
        let log=directory.appendingPathComponent(record.logName)
        guard FileManager.default.fileExists(atPath:log.path) else { return "[No saved output available.]" }
        guard (try log.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw WorkbenchError.invalid("Check log is a symbolic link.") }
        let handle=try FileHandle(forReadingFrom:log);defer{try? handle.close()}
        return String(decoding:try handle.read(upToCount:131072) ?? Data(),as:UTF8.self)
    }
}
