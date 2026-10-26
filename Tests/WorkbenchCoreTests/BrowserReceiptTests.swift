import XCTest
@testable import WorkbenchCore
final class BrowserReceiptTests:XCTestCase {
    func testPrivateMetadataAndCaptureHashRoundTrip()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=try BrowserReceiptStore(root:root,scope:"BB1S1")
        let call=BrowserCall(name:"browser_type",arguments:.object(["text":.string("PRIVATE_FORM_VALUE")]))
        var receipt=BrowserReceipt(call:call);receipt.execution = .succeeded;receipt.refresh = .failed;receipt.capture = .succeeded
        let saved=try store.saveCapture(Data("abc".utf8),id:receipt.id);receipt.captureFile=saved.0;receipt.captureSHA256=saved.1;try store.save([receipt])
        XCTAssertEqual(saved.1,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try store.load().first?.execution,.succeeded);XCTAssertTrue(receipt.summary.contains("Do not repeat"))
        let file=store.directory.appendingPathComponent("recent.json");XCTAssertFalse(try String(contentsOf:file).contains("PRIVATE_FORM_VALUE"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertThrowsError(try BrowserReceiptStore(root:root,scope:"../escape"))
    }
}
