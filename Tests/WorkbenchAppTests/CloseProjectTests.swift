import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class CloseProjectTests: XCTestCase {
    @MainActor func testCloseProjectClearsWorkspaceAndBootsClean() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("disk A".utf8).write(to:root.appendingPathComponent("a.txt"))
        let state=root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at:root) }

        let m=WorkbenchModel(stateDirectory:state)
        m.session.project=root.path; m.refreshFiles(); m.openFile("a.txt")
        XCTAssertFalse(m.files.isEmpty)
        XCTAssertEqual(m.session.file,"a.txt")

        m.closeProject()
        XCTAssertEqual(m.session.project,"")
        XCTAssertEqual(m.session.file,"")
        XCTAssertTrue(m.files.isEmpty)
        XCTAssertNil(m.error)

        // A fresh launch reads persisted state and must come up with no project.
        let restored=WorkbenchModel(stateDirectory:state)
        XCTAssertEqual(restored.session.project,"")
        XCTAssertTrue(restored.editorDocuments.isEmpty)
    }
}
