import Foundation

public struct ReviewedPatch: Equatable, Sendable {
    public struct FileChange: Equatable, Sendable {
        public let path: String
        public let isNewFile: Bool
        public let isDeleted: Bool
    }

    public let text: String
    public let changes: [FileChange]
    private let gitDiff: String

    public init(text: String, workspace: Workspace) throws {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty, normalized.utf8.count <= 512_000 else {
            throw WorkbenchError.invalid("The patch is empty or exceeds 512 KB.")
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parsed: [FileChange] = []
        var diffLines: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("WAMPUM DELETE FILE: ") {
                let path = String(line.dropFirst("WAMPUM DELETE FILE: ".count)).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      !path.split(separator: "/").contains(".git"),
                      !path.split(separator: "/").contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) else {
                    throw WorkbenchError.invalid("Delete paths must stay inside the project and cannot target Git metadata or environment files.")
                }
                _ = try workspace.resolve(path)
                parsed.append(FileChange(path: path, isNewFile: false, isDeleted: true))
                index += 1
                continue
            }
            guard line.hasPrefix("diff --git a/") else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
                throw WorkbenchError.invalid("Expected a unified Git diff. No project files were changed.")
            }
            diffLines.append(line)
            guard let separator = line.range(of: " b/", options: .backwards) else {
                throw WorkbenchError.invalid("Invalid diff file header.")
            }
            let headerPrefix = "diff --git a/"
            let oldPath = String(line[line.index(line.startIndex, offsetBy: headerPrefix.count)..<separator.lowerBound])
            let path = String(line[separator.upperBound...])
            guard oldPath == path, !path.isEmpty, !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."),
                  !path.split(separator: "/").contains(".git"),
                  !path.split(separator: "/").contains(where: { $0 == ".env" || $0.hasPrefix(".env.") }) else {
                throw WorkbenchError.invalid("Patch paths must stay inside the project and cannot target Git metadata or environment files.")
            }
            index += 1
            var isNew = false
            var isDeleted = false
            var hasHunk = false
            var oldMarker: String?
            var newMarker: String?
            while index < lines.count, !lines[index].hasPrefix("diff --git "), !lines[index].hasPrefix("WAMPUM DELETE FILE: ") {
                let item = lines[index]
                diffLines.append(item)
                if item.hasPrefix("new file mode ") {
                    guard item == "new file mode 100644" else { throw WorkbenchError.invalid("Patch file mode changes and symbolic links are not supported.") }
                    isNew = true
                }
                if item.hasPrefix("deleted file mode ") {
                    guard item == "deleted file mode 100644" else { throw WorkbenchError.invalid("Patch file mode changes and symbolic links are not supported.") }
                    isDeleted = true
                }
                if item.hasPrefix("old mode ") || item.hasPrefix("new mode ") {
                    throw WorkbenchError.invalid("Patch file mode changes are not supported.")
                }
                if item.hasPrefix("rename from ") || item.hasPrefix("rename to ") || item.hasPrefix("Binary files ") {
                    throw WorkbenchError.invalid("File renames and binary patches are not supported.")
                }
                if item.hasPrefix("--- ") { oldMarker = String(item.dropFirst(4)) }
                if item.hasPrefix("+++ ") { newMarker = String(item.dropFirst(4)) }
                if item.hasPrefix("@@ ") { hasHunk = true }
                index += 1
            }
            guard hasHunk, let oldMarker, let newMarker else {
                throw WorkbenchError.invalid("Each patch file needs a complete text-file hunk for its declared path.")
            }
            guard !(isNew && isDeleted), newMarker == (isDeleted ? "/dev/null" : "b/\(path)") else {
                throw WorkbenchError.invalid("Patch create/delete markers do not match \(path).")
            }
            let url = try workspace.resolve(path, existing: !isNew)
            let exists = FileManager.default.fileExists(atPath: url.path)
            guard isNew ? !exists : exists else {
                throw WorkbenchError.invalid("Patch create/modify status does not match the current file: \(path)")
            }
            if !isNew { _ = try workspace.read(path) }
            if isNew, oldMarker != "/dev/null" {
                throw WorkbenchError.invalid("A new file must use /dev/null as its old path.")
            }
            if !isNew, oldMarker != "a/\(path)" {
                throw WorkbenchError.invalid("Patch old path does not match \(path).")
            }
            parsed.append(FileChange(path: path, isNewFile: isNew, isDeleted: isDeleted))
            guard parsed.count <= 32 else { throw WorkbenchError.invalid("A single patch may change at most 32 files.") }
        }
        guard !parsed.isEmpty, Set(parsed.map(\.path)).count == parsed.count else {
            throw WorkbenchError.invalid("The patch has no changes or repeats a file path.")
        }
        self.text = normalized.hasSuffix("\n") ? normalized : normalized + "\n"
        self.gitDiff = diffLines.isEmpty ? "" : diffLines.joined(separator: "\n") + "\n"
        self.changes = parsed
    }

    public func validate(root: URL) throws {
        if !gitDiff.isEmpty { try runGit(arguments: ["apply", "--check", "--whitespace=nowarn", "-"], root: root) }
    }

    @discardableResult
    public func apply(root: URL, backupDirectory: URL) throws -> URL {
        try validate(root: root)
        var snapshots: [Snapshot] = []
        let workspace = try Workspace(root: root)
        for change in changes {
            let url = try workspace.resolve(change.path, existing: !change.isNewFile)
            if change.isNewFile {
                snapshots.append(Snapshot(path: change.path, data: nil, permissions: nil))
            } else {
                let values = try FileManager.default.attributesOfItem(atPath: url.path)
                snapshots.append(Snapshot(path: change.path, data: try Data(contentsOf: url), permissions: values[.posixPermissions] as? Int))
            }
        }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL = backupDirectory.appendingPathComponent("patch-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshots).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        do {
            if !gitDiff.isEmpty { try runGit(arguments: ["apply", "--whitespace=nowarn", "-"], root: root) }
            for change in changes where change.isDeleted {
                let url = try workspace.resolve(change.path, existing: false)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            for change in changes {
                let url = try workspace.resolve(change.path, existing: false)
                guard FileManager.default.fileExists(atPath: url.path) != change.isDeleted else {
                    throw WorkbenchError.invalid("Patch result did not match its file operation: \(change.path)")
                }
            }
            return backupURL
        } catch {
            for snapshot in snapshots {
                let url = try? workspace.resolve(snapshot.path, existing: false)
                guard let url else { continue }
                if let data = snapshot.data {
                    try? data.write(to: url, options: .atomic)
                    if let permissions = snapshot.permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            throw error
        }
    }

    private struct Snapshot: Codable {
        let path: String
        let data: Data?
        let permissions: Int?
    }

    private func runGit(arguments: [String], root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(gitDiff.utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkbenchError.invalid(detail.isEmpty ? "Git rejected the patch. No project files were changed." : "Git rejected the patch: \(detail)")
        }
    }
}
