import XCTest
@testable import WorkbenchCore

/// Opt-in measurements use only synthetic text and the installed local model.
final class ModelProfileTests: XCTestCase {
    func testInstalledQwenContextAndRecovery() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_PROFILE_TEST"] == "1" else { throw XCTSkip("Set WAMPUM_PROFILE_TEST=1 for local hardware measurements.") }
        let client = try OllamaClient()
        let models = try await client.models()
        let name = "lukey03/Qwen3.5-9B-abliterated:latest"
        guard models.contains(where: { $0.name == name }) else { throw XCTSkip("Expected installed model is absent; no substitute downloaded.") }
        let info = try await client.show(name)
        XCTAssertFalse(info.capabilities?.contains("vision") == true)
        for (context, rows) in [(4096, 80), (8192, 240), (16384, 480)] {
            var records = (0..<rows).map { "Record \($0): synthetic local fixture, status pending." }
            records[rows / 2] = "TARGET_MARKER: MARSH_PURPLE_742"
            let prompt = records.joined(separator: "\n") + "\nReturn only the value of TARGET_MARKER."
            let packet = try ContextPacket.build(system: "Read the supplied records and answer briefly.", history: [ChatMessage(role: "user", content: prompt)], context: context)
            let start = Date()
            let reply = try await client.chat(model: name, packet: packet, context: context, thinking: false, supportsThinking: info.capabilities?.contains("thinking") == true)
            let elapsed = Date().timeIntervalSince(start)
            let rate = Double(reply.eval_count ?? 0) / max((reply.eval_duration ?? 0) / 1_000_000_000, 0.001)
            print("PROFILE context=\(context) rows=\(rows) seconds=\(String(format: "%.2f", elapsed)) prompt_tokens=\(reply.prompt_eval_count ?? -1) output_tokens=\(reply.eval_count ?? -1) tokens_per_second=\(String(format: "%.2f", rate)) answer=\(reply.message.content.prefix(100))")
            XCTAssertTrue(reply.message.content.contains("MARSH_PURPLE_742"), "Marker retrieval failed at \(context)")
        }
        let packet = try ContextPacket.build(system: "Answer briefly.", history: [ChatMessage(role: "user", content: "Reply READY.")], context: 8192)
        let task = Task { try await client.chat(model: name, packet: packet, context: 8192, thinking: false, supportsThinking: true) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned normally") } catch { print("PROFILE cancellation=\(error)") }
        let reply = try await client.chat(model: name, packet: packet, context: 8192, thinking: false, supportsThinking: true)
        XCTAssertTrue(reply.message.content.contains("READY"))
        print("PROFILE recovery=READY")
    }
}
