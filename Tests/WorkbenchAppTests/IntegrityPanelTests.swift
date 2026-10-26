import XCTest
import CryptoKit
@testable import Wampum
@testable import WorkbenchCore

final class IntegrityPanelTests:XCTestCase {
    @MainActor func fixture()throws->(URL,IntegrityModel,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models=root.appendingPathComponent("models"),blobs=models.appendingPathComponent("blobs"),manifests=models.appendingPathComponent("manifests/fixture/model"),context=root.appendingPathComponent("context")
        for url in [blobs,manifests,context]{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let bytes=Data("WEIGHTS".utf8),hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        try bytes.write(to:blobs.appendingPathComponent("sha256-"+hash))
        let layer:[String:Any]=["digest":"sha256:"+hash,"size":bytes.count]
        let manifest=manifests.appendingPathComponent("latest")
        try JSONSerialization.data(withJSONObject:["config":layer,"layers":[layer]]).write(to:manifest)
        try Data("ORIGINAL_NOTE".utf8).write(to:context.appendingPathComponent("notes.md"))
        let model=IntegrityModel(directory:root.appendingPathComponent("state"));model.modelRoot=models.path;model.manifestPath=manifest.path;model.contextRoots=[context.path]
        let baseline=root.appendingPathComponent("baseline.json")
        let snapshot=try IntegrityCheck.snapshot(IntegrityRecipe(modelRoot:models.path,manifest:manifest.path,contextRoots:[context.path]))
        try IntegrityCheck.writeNew(JSONEncoder().encode(snapshot),to:baseline.path);model.load(baseline)
        return(root,model,baseline)
    }
    @MainActor func finish(_ model:IntegrityModel)async throws {
        for _ in 0..<300{if !model.busy{return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Integrity work did not finish")
    }
    @MainActor func testReviewCompareAndPrivateReportExportPreserveBaseline()async throws {
        let(root,model,baseline)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try Data(contentsOf:baseline)
        XCTAssertNotNil(model.baseline);XCTAssertNil(model.report)
        model.check();try await finish(model);XCTAssertEqual(model.report?.status,"unchanged")
        try Data("NEW_NOTE".utf8).write(to:root.appendingPathComponent("context/notes.md"))
        model.check();try await finish(model);XCTAssertEqual(model.report?.status,"changes-detected")
        let report=root.appendingPathComponent("report.json");try model.exportReport(to:report)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:report.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertFalse(try String(contentsOf:report).contains("NEW_NOTE"))
        XCTAssertThrowsError(try model.exportReport(to:report))
        XCTAssertThrowsError(try model.exportReport(to:root.appendingPathComponent("context/report.json")))
        XCTAssertEqual(try Data(contentsOf:baseline),original)
    }
    @MainActor func testNewBaselineNeverReplacesPreviousObservation()async throws {
        let(root,model,baseline)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try Data(contentsOf:baseline)
        model.createBaseline();try await finish(model)
        XCTAssertNil(model.error);XCTAssertNotEqual(model.baselinePath,baseline.path);XCTAssertEqual(model.availableBaselines.count,1)
        let first=model.baselinePath;model.createBaseline();try await finish(model)
        XCTAssertNotEqual(model.baselinePath,first);XCTAssertEqual(model.availableBaselines.count,2)
        XCTAssertEqual(try Data(contentsOf:baseline),original)
    }
    @MainActor func testChangedOrCorruptBaselineAndIncompleteSourceDoNotPass()async throws {
        let(root,model,baseline)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try Data(contentsOf:baseline);try Data("broken".utf8).write(to:baseline)
        model.check();try await finish(model);XCTAssertNil(model.report);XCTAssertNotNil(model.error)
        model.load(baseline);XCTAssertNil(model.baseline);XCTAssertEqual(try String(contentsOf:baseline),"broken")
        try original.write(to:baseline);model.load(baseline)
        let blob=try XCTUnwrap(model.baseline?.entries.first{$0.kind=="model-blob"});try FileManager.default.removeItem(atPath:blob.path)
        model.check();try await finish(model);XCTAssertEqual(model.report?.status,"incomplete");XCTAssertFalse(model.report?.complete ?? true)
        model.createBaseline();try await finish(model);XCTAssertNotNil(model.error);XCTAssertTrue(model.availableBaselines.isEmpty)
    }
    @MainActor func testCancellationDiscardsReportAndLeavesBaselineUntouched()async throws {
        let(root,model,baseline)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try Data(contentsOf:baseline)
        model.check();model.cancel();try await finish(model)
        XCTAssertNil(model.report);XCTAssertNil(model.error);XCTAssertTrue(model.message.contains("cancelled"));XCTAssertEqual(try Data(contentsOf:baseline),original)
    }
}
