import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class CoinDroppaReleaseLiveTests: XCTestCase {
    @MainActor func testLocalQwenReceivesMultiFileSourceReviewRequest() async throws {
        guard let projectPath = ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_ROOT"] else {
            throw XCTSkip("Opt-in local-model check against Coin Droppa's release working set.")
        }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        let sourceFiles = ["README.md", "PUNCHLIST.md", "AGENTS.md"]
        let sources = try Dictionary(uniqueKeysWithValues: sourceFiles.map { path in
            (path, try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8))
        })
        let stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Wampum-CoinDroppa-Release-Live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let model = WorkbenchModel(stateDirectory: stateDirectory)
        model.models = try await model.client.models()
        let selectedModel = "lukey03/Qwen3.5-9B-abliterated:latest"
        guard model.models.contains(where: { $0.name == selectedModel }) else {
            throw XCTSkip("The installed local Qwen model is not available.")
        }
        model.session.project = project.path
        model.session.model = selectedModel
        model.session.context = 16384
        model.includeOpenFiles = true
        model.evidenceReviewMode = true
        model.session.prompt = "We still need to finish Coin Droppa's release. Read all attached project documents and give the next concrete work slice that Wampum can complete end to end. Distinguish the portfolio preview from the transaction-enabled privacy product. Name exact files, existing commands and acceptance checks. Only recommend work supported by these sources; quote exact evidence for the current state and label missing details. Do not claim any source file or check was inspected unless attached."
        for path in sourceFiles { model.openFile(path) }
        XCTAssertEqual(model.session.draft, sources["AGENTS.md"])
        model.session.messages = [
            ChatMessage(role: "user", content: "How should we launch Coin Droppa?"),
            ChatMessage(role: "assistant", content: "The release is live, the broadcaster is integrated, and sponsors are paid automatically.")
        ]

        model.send()
        XCTAssertTrue(model.showRequestReview, model.error ?? "No request preview")
        for path in sourceFiles { XCTAssertTrue(model.requestPreview.contains("UNTRUSTED EDITOR [\(path)]")) }
        XCTAssertTrue(model.requestPreview.contains("EVIDENCE REVIEW MODE"))
        XCTAssertTrue(model.requestPreview.contains("mixer.html"))
        XCTAssertTrue(model.requestPreview.contains("Gate 1 — prove the privacy flow"))
        XCTAssertTrue(model.requestPreview.contains("Do not claim that board physics"))
        XCTAssertFalse(model.requestPreview.contains("sponsors are paid automatically"))
        XCTAssertFalse(model.requestPreview.contains(project.path))

        let resultDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_RESULT_DIR"] ?? "/private/tmp/Wampum-CoinDroppa-Evaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previewURL = resultDirectory.appendingPathComponent("coin-droppa-multifile-request.txt")
        try Data(model.requestPreview.utf8).write(to: previewURL, options: .atomic)
        model.sendReviewedRequest()
        for _ in 0..<1800 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.busy, "Local model request timed out; preview retained at \(previewURL.path)")
        let answer = try XCTUnwrap(model.session.messages.last(where: { $0.role == "assistant" })?.content)
        let responseURL = resultDirectory.appendingPathComponent("coin-droppa-multifile-response.txt")
        try Data(answer.utf8).write(to: responseURL, options: .atomic)
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("COIN DROPPA RELEASE WORKING-SET REVIEW model=\(selectedModel) files=\(sourceFiles.joined(separator: ",")) preview=\(previewURL.path) response=\(responseURL.path) stop=\(model.session.messages.last?.stopReason ?? "unknown")")
        print(answer)
    }
}
