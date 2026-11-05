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

        // Simulate a check having run against this project.
        m.command="npm run compile"; m.output="Saved check in \(root.path):\n$ npm run compile\nState: completed"

        m.closeProject()
        XCTAssertEqual(m.session.project,"")
        XCTAssertEqual(m.session.file,"")
        XCTAssertTrue(m.files.isEmpty)
        XCTAssertNil(m.error)
        // The Check Runner pane must not carry the closed project's command or output.
        XCTAssertEqual(m.command,"")
        XCTAssertEqual(m.output,"No check run yet.")

        // A fresh launch reads persisted state and must come up with no project.
        let restored=WorkbenchModel(stateDirectory:state)
        XCTAssertEqual(restored.session.project,"")
        XCTAssertTrue(restored.editorDocuments.isEmpty)
    }
}
