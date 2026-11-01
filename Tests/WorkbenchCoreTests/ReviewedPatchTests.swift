import Foundation
import XCTest
@testable import WorkbenchCore

final class ReviewedPatchTests: XCTestCase {
    func testAppliesReviewedTextPatchAndNewFileWithLocalBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("old line\n".utf8).write(to: root.appendingPathComponent("README.md"))

        let patchText = """
        diff --git a/README.md b/README.md
        index 4a7f2b4..a4d7d8e 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -old line
        +new line
        diff --git a/docs/guide.md b/docs/guide.md
        new file mode 100644
        index 0000000..3e75765
        --- /dev/null
        +++ b/docs/guide.md
        @@ -0,0 +1 @@
        +Guide
        """
        let patch = try ReviewedPatch(text: patchText, workspace: Workspace(root: root))
        XCTAssertEqual(patch.changes.map(\.path), ["README.md", "docs/guide.md"])
        XCTAssertFalse(patch.changes[0].isNewFile)
        XCTAssertTrue(patch.changes[1].isNewFile)
        let backup = try patch.apply(root: root, backupDirectory: root.appendingPathComponent("private-backups"))

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8), "new line\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/guide.md"), encoding: .utf8), "Guide\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRejectsPathsOutsideWorkspaceAndEnvironmentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)

        for path in ["../outside.txt", ".env", "config/.env.local", ".git/config"] {
            let old = "a/\(path)"
            let proposed = "b/\(path)"
            let diff = """
            diff --git \(old) \(proposed)
            --- \(old)
            +++ \(proposed)
            @@ -1 +1 @@
            -before
            +after
            """
            XCTAssertThrowsError(try ReviewedPatch(text: diff, workspace: Workspace(root: root)), path)
        }
    }

    func testFileExplorerSkipsGeneratedBuildTrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("contracts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("artifacts/contracts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source".utf8).write(to: root.appendingPathComponent("contracts/Pool.sol"))
        try Data("compiled".utf8).write(to: root.appendingPathComponent("artifacts/contracts/Pool.json"))
        try Data("generated".utf8).write(to: root.appendingPathComponent("cache/state.json"))

        XCTAssertEqual(try Workspace(root: root).files(), ["contracts/Pool.sol"])
    }

    func testAppliesDeletesAndRejectsSymlinkModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("file.txt"))

        let deletion = """
        diff --git a/file.txt b/file.txt
        deleted file mode 100644
        --- a/file.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -before
        """
        let deletePatch = try ReviewedPatch(text: deletion, workspace: Workspace(root: root))
        let backup = try deletePatch.apply(root: root, backupDirectory: root.appendingPathComponent("private-backups"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        try Data("legacy source\n".utf8).write(to: root.appendingPathComponent("legacy.js"))
        let compactDelete = try ReviewedPatch(text: "WAMPUM DELETE FILE: legacy.js", workspace: Workspace(root: root))
        let compactBackup = try compactDelete.apply(root: root, backupDirectory: root.appendingPathComponent("private-backups"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: compactBackup.path))

        let symlink = """
        diff --git a/link b/link
        new file mode 120000
        --- /dev/null
        +++ b/link
        @@ -0,0 +1 @@
        +target
        """
        XCTAssertThrowsError(try ReviewedPatch(text: symlink, workspace: Workspace(root: root)))
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
