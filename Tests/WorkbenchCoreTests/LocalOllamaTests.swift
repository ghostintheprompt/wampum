import XCTest
@testable import WorkbenchCore
final class LocalOllamaTests:XCTestCase {
    func testLiveDiscoveryCapabilitiesAndReply() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_LIVE_TEST"] == "1" else { throw XCTSkip("Set WAMPUM_LIVE_TEST=1 for the installed local model smoke test.") }
        let client=try OllamaClient();let models=try await client.models()
        guard let model=models.first(where:{$0.name.lowercased().contains("qwen")}) else { throw WorkbenchError.invalid("No installed Qwen completion model.") }
        let info=try await client.show(model.name)
        let packet=try ContextPacket.build(system:"Answer briefly.",history:[ChatMessage(role:"user",content:"Reply with the single word READY.")],context:4096)
        let reply=try await client.chat(model:model.name,packet:packet,context:4096,thinking:false,supportsThinking:info.capabilities?.contains("thinking")==true)
        XCTAssertFalse(reply.message.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        print("LOCAL SMOKE: model=\(model.name), capabilities=\(info.capabilities ?? []), prompt_tokens=\(reply.prompt_eval_count ?? -1), output_tokens=\(reply.eval_count ?? -1), response=\(reply.message.content.prefix(80))")
    }
    func testActiveLocalGenerationCancellationAndNextRequest() async throws {
        guard ProcessInfo.processInfo.environment["WAMPUM_LIVE_TEST"] == "1" else {throw XCTSkip("Opt-in installed model cancellation check.")}
        let client=try OllamaClient(), name="lukey03/Qwen3.5-9B-abliterated:latest"
        guard try await client.models().contains(where:{$0.name==name}) else {throw XCTSkip("Exact installed model absent; no download.")}
        let capabilities=try await client.show(name).capabilities ?? []
        let ready=try ContextPacket.build(system:"Answer briefly.",history:[ChatMessage(role:"user",content:"Reply with READY only.")],context:4096)
        let warmStart=Date()
        let warm=try await client.chat(model:name,packet:ready,context:4096,thinking:false,supportsThinking:capabilities.contains("thinking"),timeout:60)
        XCTAssertTrue(warm.message.content.contains("READY"))
        print("LIVE warmup_seconds=\(Date().timeIntervalSince(warmStart)) load_seconds=\((warm.load_duration ?? -1)/1_000_000_000) prompt_tokens=\(warm.prompt_eval_count ?? -1) output_tokens=\(warm.eval_count ?? -1)")
        let packet=try ContextPacket.build(system:"Follow the requested format.",history:[ChatMessage(role:"user",content:"Write the integers from 1 through 1000, each on its own line.")],context:4096)
        let task=Task{try await client.chat(model:name,packet:packet,context:4096,thinking:false,supportsThinking:capabilities.contains("thinking"),timeout:60)}
        try await Task.sleep(nanoseconds:500_000_000)
        let start=Date();task.cancel()
        do{_ = try await task.value;XCTFail("Generation completed before cancellation could be exercised")}catch is CancellationError{}catch{XCTFail("Unexpected cancellation error: \(error)")}
        let cancelSeconds=Date().timeIntervalSince(start)
        XCTAssertLessThan(cancelSeconds,3)
        let recoveryStart=Date()
        let reply=try await client.chat(model:name,packet:ready,context:4096,thinking:false,supportsThinking:capabilities.contains("thinking"),timeout:60)
        XCTAssertTrue(reply.message.content.contains("READY"))
        print("LIVE cancellation_seconds=\(cancelSeconds) recovery_seconds=\(Date().timeIntervalSince(recoveryStart)) recovery_load_seconds=\((reply.load_duration ?? -1)/1_000_000_000) done_reason=\(reply.done_reason ?? "unknown") recovery_prompt_tokens=\(reply.prompt_eval_count ?? -1) recovery_output_tokens=\(reply.eval_count ?? -1). Warmed request cancellation and next local request verified; no server compute-stop claim.")

    }

}
