import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class CoinDroppaReleaseLiveTests: XCTestCase {
    @MainActor func testLocalQwenReceivesSourceOnlyReleaseReviewRequest() async throws {
        guard let projectPath = ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_ROOT"] else {
            throw XCTSkip("Opt-in local-model check against the Coin Droppa release README.")
        }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        let readme = try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8)
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
        model.session.context = 8192
        model.evidenceReviewMode = true
        model.session.prompt = "Audit the attached Coin Droppa README for an owner preparing a clean release. Give a compact table with Topic, What works, and What remains. Cover: local start command/page, board animation trigger, portfolio build behavior, privacy limitations, and revenue/prize automation. Quote exact phrases from README.md. Separate implemented behavior from plans and release gaps. Do not invent implementation details or claim a test passed unless this file says so. End with the next release gate."
        model.openFile("README.md")
        XCTAssertEqual(model.session.draft, readme)
        model.session.messages = [
            ChatMessage(role: "user", content: "How should we launch Coin Droppa?"),
            ChatMessage(role: "assistant", content: "The release is live, the broadcaster is integrated, and sponsors are paid automatically.")
        ]

        model.send()
        XCTAssertTrue(model.showRequestReview, model.error ?? "No request preview")
        XCTAssertTrue(model.requestPreview.contains("UNTRUSTED EDITOR [README.md]"))
        XCTAssertTrue(model.requestPreview.contains("EVIDENCE REVIEW MODE"))
        XCTAssertTrue(model.requestPreview.contains("mixer.html"))
        XCTAssertFalse(model.requestPreview.contains("sponsors are paid automatically"))
        XCTAssertFalse(model.requestPreview.contains(project.path))

        let resultDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_RESULT_DIR"] ?? "/private/tmp/Wampum-CoinDroppa-Evaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previewURL = resultDirectory.appendingPathComponent("coin-droppa-release-request.txt")
        try Data(model.requestPreview.utf8).write(to: previewURL, options: .atomic)
        model.sendReviewedRequest()
        for _ in 0..<1800 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.busy, "Local model request timed out; preview retained at \(previewURL.path)")
        let answer = try XCTUnwrap(model.session.messages.last(where: { $0.role == "assistant" })?.content)
        let responseURL = resultDirectory.appendingPathComponent("coin-droppa-release-response.txt")
        try Data(answer.utf8).write(to: responseURL, options: .atomic)
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("COIN DROPPA RELEASE REVIEW model=\(selectedModel) preview=\(previewURL.path) response=\(responseURL.path) stop=\(model.session.messages.last?.stopReason ?? "unknown")")
        print(answer)
    }
}
