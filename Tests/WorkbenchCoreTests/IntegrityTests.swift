import XCTest
import CryptoKit
@testable import WorkbenchCore

final class IntegrityTests:XCTestCase {
    func fixture()throws->(URL,IntegrityRecipe) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models=root.appendingPathComponent("models"),blobs=models.appendingPathComponent("blobs"),manifests=models.appendingPathComponent("manifests/fixture/model"),context=root.appendingPathComponent("context")
        for url in [blobs,manifests,context]{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let data=Data("MODEL_BYTES".utf8),hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        try data.write(to:blobs.appendingPathComponent("sha256-"+hash))
        let layer:[String:Any]=["digest":"sha256:"+hash,"size":data.count]
        try JSONSerialization.data(withJSONObject:["config":layer,"layers":[layer]]).write(to:manifests.appendingPathComponent("latest"))
        try Data("PRIVATE_CONTEXT_ORIGINAL".utf8).write(to:context.appendingPathComponent("notes.md"))
        return(root,IntegrityRecipe(modelRoot:models.path,manifest:manifests.appendingPathComponent("latest").path,contextRoots:[context.path]))
    }
    func testBlobAndContextChangesAreReportedWithoutContents()throws {
        let(root,recipe)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let initial=try IntegrityCheck.snapshot(recipe);XCTAssertTrue(initial.complete);XCTAssertEqual(initial.entries.count,3)
        let bytes=try JSONEncoder().encode(initial)
        let unchanged=try IntegrityCheck.compare(baseline:initial,current:IntegrityCheck.snapshot(recipe),baselineBytes:bytes)
        XCTAssertEqual(unchanged.status,"unchanged")
        try Data("CHANGED_PRIVATE_INSTRUCTION".utf8).write(to:root.appendingPathComponent("context/notes.md"))
        try Data("new".utf8).write(to:root.appendingPathComponent("context/new.json"))
        let changed=try IntegrityCheck.compare(baseline:initial,current:IntegrityCheck.snapshot(recipe),baselineBytes:bytes)
        XCTAssertEqual(changed.status,"changes-detected");XCTAssertEqual(Set(changed.changes.map(\.change)),Set(["added","changed"]))
        let report=String(decoding:try JSONEncoder().encode(changed),as:UTF8.self)
        XCTAssertFalse(report.contains("CHANGED_PRIVATE_INSTRUCTION"));XCTAssertFalse(report.contains("PRIVATE_CONTEXT_ORIGINAL"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("context/notes.md"))
        let deleted=try IntegrityCheck.compare(baseline:initial,current:IntegrityCheck.snapshot(recipe),baselineBytes:bytes)
        XCTAssertTrue(deleted.changes.contains{$0.change=="removed-or-unreadable"})
        let blob=try XCTUnwrap(initial.entries.first{$0.kind=="model-blob"})
        try Data("ALTERED".utf8).write(to:URL(fileURLWithPath:blob.path))
        let invalid=try IntegrityCheck.snapshot(recipe)
        XCTAssertFalse(invalid.complete);XCTAssertTrue(invalid.issues.contains{$0.contains("digest mismatch")})
        XCTAssertEqual(try IntegrityCheck.compare(baseline:initial,current:invalid,baselineBytes:bytes).status,"incomplete")
    }
    func testLinksMissingBlobsAndInvalidManifestsAreIncomplete()throws {
        let(root,recipe)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let blob=try XCTUnwrap(try IntegrityCheck.snapshot(recipe).entries.first{$0.kind=="model-blob"})
        try FileManager.default.removeItem(atPath:blob.path)
        XCTAssertFalse(try IntegrityCheck.snapshot(recipe).complete)
        let outside=root.appendingPathComponent("outside.txt");try Data("MODEL_BYTES".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(atPath:blob.path,withDestinationPath:outside.path)
        XCTAssertFalse(try IntegrityCheck.snapshot(recipe).complete)
        try Data("not json".utf8).write(to:URL(fileURLWithPath:recipe.manifest))
        XCTAssertFalse(try IntegrityCheck.snapshot(recipe).complete)
        let escape=IntegrityRecipe(modelRoot:recipe.modelRoot,manifest:outside.path,contextRoots:[])
        XCTAssertThrowsError(try IntegrityCheck.snapshot(escape))
    }
    func testPrivateExclusiveBaselineAndCoverageRules()throws {
        let(root,recipe)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("baseline.json"),snapshot=try IntegrityCheck.snapshot(recipe),bytes=try JSONEncoder().encode(snapshot)
        try IntegrityCheck.writeNew(bytes,to:file.path)
        XCTAssertThrowsError(try IntegrityCheck.writeNew(Data("replacement".utf8),to:file.path))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try IntegrityCheck.writeNew(Data(),to:link.path))
        XCTAssertThrowsError(try IntegrityCheck.boundedData(link.path,limit:100000))
        try Data("hidden".utf8).write(to:root.appendingPathComponent("context/.hidden.md"))
        try Data("uncovered".utf8).write(to:root.appendingPathComponent("context/uncovered.swift"))
        XCTAssertEqual(try IntegrityCheck.snapshot(recipe).entries.count,3)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("context/linked.md"),withDestinationURL:file)
        XCTAssertFalse(try IntegrityCheck.snapshot(recipe).complete)
    }
    func testCLIRejectsReplacementAndUsesSavedRecipe()throws {
        let(root,recipe)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable=repo.appendingPathComponent(".build/debug/WampumIntegrity"),baseline=root.appendingPathComponent("baseline.json"),report=root.appendingPathComponent("report.json")
        func call(_ args:[String])throws->Int32 {
            let process=Process();process.executableURL=executable;process.arguments=args;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit();return process.terminationStatus
        }
        let baselineArgs=["baseline","--models",recipe.modelRoot,"--manifest",recipe.manifest,"--context",recipe.contextRoots[0],"--baseline",baseline.path]
        XCTAssertEqual(try call(baselineArgs),0);let original=try Data(contentsOf:baseline)
        XCTAssertEqual(try call(baselineArgs),1);XCTAssertEqual(try Data(contentsOf:baseline),original)
        XCTAssertEqual(try call(["check","--baseline",baseline.path,"--report",report.path]),0)
        XCTAssertEqual(try JSONDecoder().decode(IntegrityReport.self,from:Data(contentsOf:report)).status,"unchanged")
        try Data("new instruction".utf8).write(to:root.appendingPathComponent("context/notes.md"))
        XCTAssertEqual(try call(["check","--baseline",baseline.path]),2)
        XCTAssertEqual(try call(["check","--baseline",baseline.path,"--context",root.path]),1)
        XCTAssertEqual(try call(["check","--baseline",baseline.path,"--report",root.appendingPathComponent("context/report.json").path]),1)
        XCTAssertEqual(try Data(contentsOf:baseline),original)
    }
}
