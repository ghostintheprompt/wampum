import Foundation
import CryptoKit
import Darwin

public struct IntegrityRecipe: Codable, Equatable, Sendable {
    public let modelRoot: String
    public let manifest: String
    public let contextRoots: [String]
    public let excludedPaths: [String]
    public init(modelRoot: String, manifest: String, contextRoots: [String], excludedPaths: [String] = []) {
        self.modelRoot=modelRoot;self.manifest=manifest;self.contextRoots=contextRoots;self.excludedPaths=excludedPaths
    }
}
public struct IntegrityEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let sha256: String
    public let bytes: Int64
    public let declaredSHA256: String?
}
public struct IntegritySnapshot: Codable, Sendable {
    public let schemaVersion: String
    public let created: Date
    public let recipe: IntegrityRecipe
    public let entries: [IntegrityEntry]
    public let issues: [String]
    public var complete: Bool { issues.isEmpty }
}
public struct IntegrityChange: Codable, Sendable {
    public let path: String
    public let change: String
    public let previousSHA256: String?
    public let currentSHA256: String?
}
public struct IntegrityReport: Codable, Sendable {
    public let schemaVersion: String
    public let checked: Date
    public let baselineSHA256: String
    public let status: String
    public let complete: Bool
    public let changes: [IntegrityChange]
    public let issues: [String]
    public let inspectedFiles: Int
    public let assurance: String
}
public enum IntegrityCheck {
    public static let assurance="A local byte-integrity comparison, not a poisoning detector. The first baseline is an unverified observation. Unchanged bytes do not prove a safe model or benign instructions. The baseline is not signed or protected against the same macOS account modifying it. Context changes may be legitimate. No network, behavioral test, training-data audit or forensic attribution is performed. Directory context coverage is limited to md/json/jsonl/txt/toml/yaml/yml files outside hidden and excluded paths."
    private struct Layer: Decodable {let digest:String;let size:Int64}
    private struct Manifest: Decodable {let config:Layer;let layers:[Layer]}
    private static let extensions:Set<String>=["md","json","jsonl","txt","toml","yaml","yml"]
    private static func absolute(_ path:String)->String {URL(fileURLWithPath:path).standardizedFileURL.path}
    private static func beneath(_ file:String,_ root:String)->Bool {file == root || file.hasPrefix(root+"/")}
    public static func hashFile(_ path:String, limit:Int64) throws -> (String,Int64) {
        let fd=open(path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {throw WorkbenchError.invalid("Cannot open regular file: \(path)")}
        defer{close(fd)}
        var before=stat()
        guard fstat(fd,&before)==0, before.st_mode & S_IFMT == S_IFREG, before.st_size<=limit else {throw WorkbenchError.invalid("Not a regular file or over size limit: \(path)")}
        var hasher=SHA256(), total:Int64=0
        var buffer=[UInt8](repeating:0,count:1024*1024)
        while true {
            try Task.checkCancellation()
            let count=read(fd,&buffer,buffer.count)
            if count == -1 && errno == EINTR {continue}
            guard count>=0 else{throw WorkbenchError.invalid("Read failed: \(path)")}
            if count==0{break}
            total+=Int64(count)
            guard total<=limit else{throw WorkbenchError.invalid("File grew beyond size limit: \(path)")}
            hasher.update(data:Data(buffer.prefix(count)))
        }
        var after=stat(), named=stat()
        guard fstat(fd,&after)==0, lstat(path,&named)==0, named.st_ino==before.st_ino, named.st_dev==before.st_dev,
              before.st_size==after.st_size, total==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec else {
            throw WorkbenchError.invalid("File changed while hashing: \(path)")
        }
        return(hasher.finalize().map{String(format:"%02x",$0)}.joined(),total)
    }
    public static func snapshot(_ recipe:IntegrityRecipe)throws->IntegritySnapshot {
        guard recipe.contextRoots.count<=32 else{throw WorkbenchError.invalid("At most 32 explicit context roots.")}
        let root=URL(fileURLWithPath:recipe.modelRoot).resolvingSymlinksInPath().path
        let manifest=absolute(recipe.manifest)
        guard beneath(URL(fileURLWithPath:manifest).resolvingSymlinksInPath().path,root+"/manifests") else{throw WorkbenchError.invalid("Manifest must be inside the selected model store's manifests directory.")}
        var entries:[IntegrityEntry]=[],issues:[String]=[],seen=Set<String>(),modelBytes:Int64=0,contextBytes:Int64=0,contextFiles=0,visitedNodes=0
        func capture(_ file:String,_ kind:String,_ limit:Int64,_ declared:String?=nil) throws {
            let path=absolute(file)
            if seen.contains(path){return};seen.insert(path)
            let (hash,bytes)=try hashFile(path,limit:limit)
            if kind=="context" {contextBytes+=bytes;guard contextBytes<=128*1024*1024 else{throw WorkbenchError.invalid("Context exceeds 128 MB total.")}}
            else {modelBytes+=bytes;guard modelBytes<=64*1024*1024*1024 else{throw WorkbenchError.invalid("Model exceeds 64 GB total.")}}
            entries.append(IntegrityEntry(path:path,kind:kind,sha256:hash,bytes:bytes,declaredSHA256:declared))
            if let declared,declared != hash {issues.append("Declared digest mismatch: \(path)")}
        }
        do {
            try capture(manifest,"manifest",1024*1024)
            let data=try boundedData(manifest,limit:1024*1024)
            guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==entries.first?.sha256 else{throw WorkbenchError.invalid("Manifest changed during inspection.")}
            let parsed=try JSONDecoder().decode(Manifest.self,from:data)
            guard parsed.layers.count<=128 else{throw WorkbenchError.invalid("Manifest exceeds 128 layers.")}
            for layer in [parsed.config]+parsed.layers {
                guard layer.digest.utf8.count==71,layer.digest.range(of:"^sha256:[a-f0-9]{64}$",options:.regularExpression) != nil, layer.size>=0 else{throw WorkbenchError.invalid("Invalid declared blob digest or size.")}
                let hash=String(layer.digest.dropFirst(7)),file=root+"/blobs/sha256-"+hash
                do {
                    guard beneath(URL(fileURLWithPath:file).resolvingSymlinksInPath().path,root+"/blobs") else{throw WorkbenchError.invalid("Blob resolves outside selected store.")}
                    try capture(file,"model-blob",32*1024*1024*1024,hash)
                    if entries.first(where:{$0.path==file})?.bytes != layer.size {issues.append("Declared size mismatch: \(file)")}
                }catch{issues.append(String(describing:error))}
            }
        }catch{issues.append(String(describing:error))}
        let excluded=recipe.excludedPaths.map(absolute)
        func inspectContext(_ url:URL,depth:Int=0)throws {
            try Task.checkCancellation()
            visitedNodes+=1
            guard depth<=32,visitedNodes<=10000 else{throw WorkbenchError.invalid("Context traversal exceeds depth/node limit.")}
            let path=url.standardizedFileURL.path
            if excluded.contains(where:{beneath(path,$0)}){return}
            let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey])
            if values.isSymbolicLink==true{issues.append("Context symbolic link not followed: \(path)");return}
            if values.isDirectory==true {
                let children=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])
                guard children.count<=2000 else{throw WorkbenchError.invalid("Context directory exceeds 2,000 entries: \(path)")}
                for child in children.sorted(by:{$0.path<$1.path}) {try inspectContext(child,depth:depth+1)}
            }else if values.isRegularFile==true,extensions.contains(url.pathExtension.lowercased()) || recipe.contextRoots.contains(path) {
                contextFiles+=1;guard contextFiles<=2000 else{throw WorkbenchError.invalid("Context exceeds 2,000 files.")}
                do{try capture(path,"context",16*1024*1024)}catch{issues.append(String(describing:error))}
            }
        }
        for context in recipe.contextRoots {
            do{try inspectContext(URL(fileURLWithPath:absolute(context)))}catch{issues.append("Context unavailable: \(absolute(context)): \(error)")}
        }
        return IntegritySnapshot(schemaVersion:"wampum-integrity/v1",created:Date(),recipe:recipe,entries:entries.sorted{$0.path<$1.path},issues:issues)
    }
    public static func compare(baseline:IntegritySnapshot,current:IntegritySnapshot,baselineBytes:Data)throws->IntegrityReport {
        guard baseline.schemaVersion=="wampum-integrity/v1",current.schemaVersion==baseline.schemaVersion,baseline.recipe==current.recipe,baseline.complete,
              Set(baseline.entries.map(\.path)).count==baseline.entries.count else{throw WorkbenchError.invalid("Baseline is incomplete, unsupported or contains duplicate paths.")}
        let old=Dictionary(uniqueKeysWithValues:baseline.entries.map{($0.path,$0)}),new=Dictionary(uniqueKeysWithValues:current.entries.map{($0.path,$0)})
        let changes=Set(old.keys).union(new.keys).sorted().compactMap {path -> IntegrityChange? in
            guard old[path] != new[path] else{return nil}
            return IntegrityChange(path:path,change:old[path]==nil ? "added":new[path]==nil ? "removed-or-unreadable":"changed",previousSHA256:old[path]?.sha256,currentSHA256:new[path]?.sha256)
        }
        return IntegrityReport(schemaVersion:"wampum-integrity-report/v1",checked:Date(),baselineSHA256:SHA256.hash(data:baselineBytes).map{String(format:"%02x",$0)}.joined(),status:!current.complete ? "incomplete":changes.isEmpty ? "unchanged":"changes-detected",complete:current.complete,changes:changes,issues:current.issues,inspectedFiles:current.entries.count,assurance:assurance)
    }
    public static func boundedData(_ path:String,limit:Int)throws->Data {
        let (_,size)=try hashFile(path,limit:Int64(limit))
        let handle=try FileHandle(forReadingFrom:URL(fileURLWithPath:path));defer{try? handle.close()}
        let data=try handle.read(upToCount:limit+1) ?? Data()
        guard data.count<=limit,data.count==size else{throw WorkbenchError.invalid("Record changed or exceeds read limit.")};return data
    }
    public static func writeNew(_ data:Data,to path:String)throws {
        let fd=open(path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard fd>=0 else{throw WorkbenchError.invalid("Cannot create output; existing files are never replaced: \(path)")}
        var success=false
        defer{close(fd);if !success{unlink(path)}}
        try data.withUnsafeBytes {buffer in
            var offset=0
            while offset<buffer.count {
                let count=write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count == -1 && errno == EINTR {continue}
                guard count>0 else{throw WorkbenchError.invalid("Output write failed.")};offset+=count
            }
        }
        guard fsync(fd)==0 else{throw WorkbenchError.invalid("Output synchronization failed.")};success=true
    }
}
