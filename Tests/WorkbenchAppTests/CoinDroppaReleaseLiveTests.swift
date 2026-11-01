import XCTest
@testable import Wampum
@testable import WorkbenchCore

final class CoinDroppaReleaseLiveTests: XCTestCase {
    @MainActor func testLocalQwenReceivesMultiFileReleaseEvidence() async throws {
        guard let projectPath = ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_ROOT"] else {
            throw XCTSkip("Opt-in local-model check against Coin Droppa's release working set.")
        }
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        let sourceFiles = ["README.md", "PUNCHLIST.md", "AGENTS.md", "package.json", "scripts/build-site.js", "contracts/test/TestToken.sol"]
        let sources = try Dictionary(uniqueKeysWithValues: sourceFiles.map { path in
            (path, try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8))
        })
        let expectedAnswerURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CoinDroppaReleaseReview.expected.md")
        let expectedAnswer = try String(contentsOf: expectedAnswerURL, encoding: .utf8)
        XCTAssertLessThan(sources.values.reduce(0) { $0 + $1.utf8.count }, 32_000)

        func run(_ executable: String, arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = project
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self) + "\nExit: \(process.terminationStatus)"
        }

        let trackedFiles = try run("/usr/bin/git", arguments: ["ls-files"])
        let buildOutput = try run("/usr/bin/env", arguments: ["npm", "run", "build"])
        let publishedFiles = try run("/usr/bin/env", arguments: ["find", "dist", "-maxdepth", "2", "-type", "f", "-print"])
        let legacyReferences = try run("/usr/bin/env", arguments: ["rg", "-n", "DroppaShield|@railgun|RAILGUN|railgun|Shield and drop|Generate proof", "mixer.html", "src/railgun-browser.js", "railgunConfig.js", "package.json"])
        XCTAssertTrue(trackedFiles.contains("src/railgun-browser.js"))
        XCTAssertTrue(buildOutput.contains("published 9 files to dist/"))
        XCTAssertTrue(buildOutput.contains("Exit: 0"))
        XCTAssertTrue(publishedFiles.contains("dist/index.html"))
        XCTAssertTrue(legacyReferences.contains("src/railgun-browser.js"))
        let runID = String(UUID().uuidString.prefix(8))
        let stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Wampum-CoinDroppa-Release-Live-\(runID)")
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
        model.session.prompt = "Review Coin Droppa for the next release work slice. The only full editor drafts are README.md, PUNCHLIST.md, AGENTS.md, package.json, scripts/build-site.js, and contracts/test/TestToken.sol. Other paths appear only in captured command output; do not say their full files were reviewed. Owner direction: keep five pachinko boards, retire RAILGUN, pursue a fixed-denomination Tornado-style privacy pool. This is a requirement, not proof of implementation. The owner has not accepted a wallet-offline game preview as the requested release.\n\nReturn exactly four sections: CURRENT BUILD; LEGACY WALLET PATH; PRIVACY PRODUCT GAP; RELEASE DECISION. In each section, make at most two concise findings. For every finding, put `Source: <exact attached filename or CHECK OUTPUT number>` on one line, the next line must be `> <short exact span copied from that source>` with no extra quote marks, and then one sentence explaining the finding. A path in `git ls-files` proves only that the path exists in the working tree. Do not invent functionality, label a script a deployment script without evidence, claim privacy, or declare release readiness. Mark any unsupported detail `not established`. No intro, summary, or uncited factual claims."
        for path in sourceFiles { model.openFile(path) }
        XCTAssertEqual(model.session.draft, sources["contracts/test/TestToken.sol"])
        model.session.messages = [
            ChatMessage(role: "user", content: "How should we launch Coin Droppa?"),
            ChatMessage(role: "assistant", content: "The private pool is deployed, sponsors are paid automatically, and live draws run on every play.")
        ]

        model.output = "GIT TRACKED FILES\n" + trackedFiles
        model.attachOutput()
        model.output = "PUBLIC SITE BUILD\n" + buildOutput
        model.attachOutput()
        model.output = "PUBLISHED FILES\n" + publishedFiles
        model.attachOutput()
        model.output = "LEGACY WALLET CODE REFERENCES\n" + legacyReferences
        model.attachOutput()

        model.send()
        XCTAssertTrue(model.showRequestReview, model.error ?? "No request preview")
        for path in sourceFiles { XCTAssertTrue(model.requestPreview.contains("UNTRUSTED EDITOR [\(path)]")) }
        XCTAssertTrue(model.requestPreview.contains("CHECK OUTPUT 1 (untrusted evidence)"))
        XCTAssertTrue(model.requestPreview.contains("CHECK OUTPUT 2 (untrusted evidence)"))
        XCTAssertTrue(model.requestPreview.contains("CHECK OUTPUT 3 (untrusted evidence)"))
        XCTAssertTrue(model.requestPreview.contains("CHECK OUTPUT 4 (untrusted evidence)"))
        XCTAssertEqual(model.pendingSourceQuoteSources?["CHECK OUTPUT 2"], "PUBLIC SITE BUILD\n" + buildOutput)
        XCTAssertEqual(model.pendingSourceQuoteSources?["CHECK OUTPUT 3"], "PUBLISHED FILES\n" + publishedFiles)
        XCTAssertEqual(model.pendingSourceQuoteSources?["CHECK OUTPUT 4"], "LEGACY WALLET CODE REFERENCES\n" + legacyReferences)
        XCTAssertFalse(model.requestPreview.contains("sponsors are paid automatically"))
        XCTAssertFalse(model.requestPreview.contains(project.path))

        let resultDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAMPUM_COIN_DROPPA_RESULT_DIR"] ?? "/private/tmp/Wampum-CoinDroppa-Evaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var expectedSources = sources
        expectedSources["CHECK OUTPUT 1"] = "GIT TRACKED FILES\n" + trackedFiles
        expectedSources["CHECK OUTPUT 2"] = "PUBLIC SITE BUILD\n" + buildOutput
        expectedSources["CHECK OUTPUT 3"] = "PUBLISHED FILES\n" + publishedFiles
        expectedSources["CHECK OUTPUT 4"] = "LEGACY WALLET CODE REFERENCES\n" + legacyReferences
        let expectedReview = SourceQuoteReview(answer: expectedAnswer, sources: expectedSources)
        XCTAssertFalse(expectedReview.findings.isEmpty, "The expected review needs verifiable quotes.")
        XCTAssertFalse(expectedReview.findings.contains(where: { $0.status != .exactMatch }), expectedReview.summary)
        let expectedURL = resultDirectory.appendingPathComponent("coin-droppa-multifile-expected-answer.md")
        try Data(expectedAnswer.utf8).write(to: expectedURL, options: .atomic)
        let previewURL = resultDirectory.appendingPathComponent("coin-droppa-multifile-request-\(runID).txt")
        try Data(model.requestPreview.utf8).write(to: previewURL, options: .atomic)
        model.sendReviewedRequest()
        for _ in 0..<1800 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.busy, "Local model request timed out; preview retained at \(previewURL.path)")
        let responseURL = resultDirectory.appendingPathComponent("coin-droppa-multifile-response-\(runID).txt")
        let latestUserIndex = model.session.messages.lastIndex(where: { $0.role == "user" })
        let newAssistant = latestUserIndex.flatMap { index in
            model.session.messages.dropFirst(index + 1).first(where: { $0.role == "assistant" })
        }
        guard let assistant = newAssistant else {
            try Data(model.status.utf8).write(to: responseURL, options: .atomic)
            XCTFail("Local model produced no answer message. Status: \(model.status). Outcome saved at \(responseURL.path)")
            return
        }
        try Data(assistant.content.utf8).write(to: responseURL, options: .atomic)
        print("COIN DROPPA RELEASE REVIEW model=\(selectedModel) files=\(sourceFiles.joined(separator: ",")) preview=\(previewURL.path) response=\(responseURL.path) stop=\(assistant.stopReason ?? "unknown") status=\(model.status)")
        guard let review = assistant.sourceQuoteReview else {
            XCTFail("No source quote review was attached to the live response.")
            print(assistant.content)
            return
        }
        let lowerAnswer = assistant.content.lowercased()
        XCTAssertFalse(lowerAnswer.contains("ready for deployment"), "The owner has not accepted the wallet-offline game as the requested release.")
        XCTAssertTrue(lowerAnswer.contains("no fixed-denomination privacy pool") || lowerAnswer.contains("not implemented"), "The response must state that the requested privacy product is absent.")
        print("SOURCE QUOTE REVIEW: \(review.summary)")
        for finding in review.findings { print("QUOTE \(finding.id): \(finding.status.rawValue) citation=\(finding.citedSource ?? "none")") }
        XCTAssertFalse(review.findings.isEmpty, "The release-review response did not provide blockquoted evidence.")
        XCTAssertFalse(review.findings.contains(where: { $0.status != .exactMatch }), review.summary)
        print(assistant.content)
    }
}
