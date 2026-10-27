import Foundation

public struct LabMemory: Codable, Equatable {
    public var id: String
    public var title: String
    public var mode: String
    public var objective = ""
    public var environment = ""
    public var markers = ""
    public var attempts = ""
    public var evidence = ""
    public var nextStep = ""
    public var result = "Unverified"
    public var rejectedTools: String? = nil
    public init(id: String, title: String, mode: String) { self.id=id; self.title=title; self.mode=mode }
    public var context: String {
        """
        ACTIVE SCENARIO: \(id) / \(title)
        MODE: \(mode)
        OBJECTIVE: \(objective)
        OBSERVED ENVIRONMENT: \(environment)
        OBSERVED MARKERS: \(markers)
        ATTEMPTS / RESULTS: \(attempts)
        EVIDENCE REFERENCES: \(evidence)
        RESULT STATUS: \(result)
        REJECTED TOOLS / REASONS / RETRY CONDITIONS: \(rejectedTools ?? "None recorded")
        Do not repeat a rejected tool request with the same arguments and unchanged conditions. Permission denials require an explicit permission change, not a renamed tool, alternate transport, or equivalent workaround. Invalid arguments require a concrete correction. Missing tools require verified availability. A transient failure may receive one bounded retry only when the tool permits it. Otherwise record the blocker and choose an available approach within scope. Never claim a tool succeeded after rejection.
        NEXT STEP: \(nextStep)
        These are operator-maintained notes, not fresh tool observations. Verify the current environment and markers before drawing conclusions. A proposal, an agent report, and a grader-confirmed outcome are different evidence levels. Do not claim browser access or completed actions without tool evidence.
        """
    }
}
public struct LabEntry: Codable, Identifiable {
    public let id: String
    public let title: String
    public let mode: String
    public let status: String
    public let folder: String
    public init(id:String,title:String,mode:String,status:String,folder:String){self.id=id;self.title=title;self.mode=mode;self.status=status;self.folder=folder}
}
public struct ScenarioStore {
    public let directory: URL
    public init(directory:URL) { self.directory=directory.appendingPathComponent("scenarios") }
    private func validate(_ id:String) throws {
        guard !id.isEmpty, id.count<=80, id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else { throw WorkbenchError.invalid("Scenario IDs may contain letters, digits, underscores and hyphens.") }
    }
    private func prepare() throws { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    private func write(_ data:Data,to url:URL) throws {
        try prepare();try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func entries() throws -> [LabEntry] {
        let url=directory.appendingPathComponent("index.json")
        return FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode([LabEntry].self,from:Data(contentsOf:url)) : []
    }
    public func importIndex(_ url:URL) throws -> [LabEntry] {
        let data=try Data(contentsOf:url)
        guard data.count<=262144 else { throw WorkbenchError.invalid("Scenario index is too large.") }
        let entries=try JSONDecoder().decode([LabEntry].self,from:data)
        guard entries.count<=200,Set(entries.map(\.id)).count==entries.count else {throw WorkbenchError.invalid("Scenario index has duplicate IDs or too many entries.")}
        for entry in entries {try validate(entry.id);_ = try Workspace(root:URL(fileURLWithPath:entry.folder))}
        try write(try JSONEncoder().encode(entries),to:directory.appendingPathComponent("index.json"));return entries
    }
    public func save(_ session:Session) throws {
        guard let lab=session.lab else {throw WorkbenchError.invalid("No active scenario.")}
        try validate(lab.id)
        try write(try JSONEncoder().encode(session.persistableEditorSession),to:directory.appendingPathComponent(lab.id+".json"))
    }
    public func load(_ id:String) throws -> Session? {
        try validate(id);let url=directory.appendingPathComponent(id+".json")
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let session=try JSONDecoder().decode(Session.self,from:Data(contentsOf:url))
        guard session.lab?.id==id else{throw WorkbenchError.invalid("Saved scenario ID does not match its filename.")}
        return session
    }
    public func saveGeneral(_ session:Session) throws {try write(try JSONEncoder().encode(session.persistableEditorSession),to:directory.appendingPathComponent("general.json"))}
    public func loadGeneral() throws -> Session? {
        let url=directory.appendingPathComponent("general.json")
        return FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode(Session.self,from:Data(contentsOf:url)) : nil
    }
}
