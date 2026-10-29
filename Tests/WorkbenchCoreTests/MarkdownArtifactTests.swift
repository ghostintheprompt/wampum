import XCTest
@testable import WorkbenchCore
final class MarkdownArtifactTests: XCTestCase {
    func testNestedCodeFencesAndTrailingSections() {
        let body="# Report\n\n```sh\nprintf hello\n```\n\n## Findings\nComplete.\n"
        XCTAssertEqual(MarkdownArtifact.replacement(in:"File:\n````markdown\n"+body+"````\nReview this."),body)
        XCTAssertNil(MarkdownArtifact.replacement(in:"````markdown\n"+body))
    }
    func testTranscriptRetainsAllBodiesInOrderAndCutoffStatus() throws {
        let first=ChatMessage(role:"user",content:"Keep every section")
        var partial=ChatMessage(role:"assistant",content:"# Start\n```python\nprint('résumé')\n```\n")
        partial.stopReason="length"
        let last=ChatMessage(role:"assistant",content:"## Final section\nComplete final paragraph.")
        let output=MarkdownArtifact.transcript([first,partial,last])
        XCTAssertTrue(output.contains("INCOMPLETE"))
        XCTAssertTrue(output.contains(partial.content));XCTAssertTrue(output.contains(last.content))
        XCTAssertLessThan(output.range(of:partial.content)!.lowerBound,output.range(of:last.content)!.lowerBound)
        let replies=MarkdownArtifact.transcript([first,partial,last],assistantOnly:true)
        XCTAssertFalse(replies.contains(first.content));XCTAssertTrue(replies.contains(partial.content));XCTAssertTrue(replies.contains(last.content))
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".md")
        defer {try? FileManager.default.removeItem(at:file)}
        try MarkdownArtifact.export(output,to:file)
        XCTAssertEqual(try Data(contentsOf:file),Data(output.utf8))
    }
    func testMalformedHistoricalFenceCannotSwallowFollowingMessages() {
        let partial=ChatMessage(role:"assistant",content:"# Partial\n```python\nprint(1)")
        let final=ChatMessage(role:"assistant",content:"## Final\nThe last paragraph.")
        let exported=MarkdownArtifact.transcript([partial,final])
        XCTAssertTrue(exported.contains(partial.content))
        XCTAssertTrue(exported.contains(final.content))
        XCTAssertTrue(exported.contains("unclosed code fence"))
        XCTAssertFalse(MarkdownArtifact.hasUnclosedFence(exported))
    }
    func testResponseBudgetLeavesContextHeadroom() throws {
        XCTAssertEqual(OllamaClient.responseTokenLimit(context:8192,inputEstimate:1000),4096)
        XCTAssertEqual(OllamaClient.responseTokenLimit(context:4096,inputEstimate:2000),1584)
        let packet=try ContextPacket.build(system:"Research",history:[ChatMessage(role:"user",content:"Write a report")],context:8192,outputReserve:4096)
        XCTAssertLessThanOrEqual(packet.estimatedTokens,4096)
    }
    func testExportPreservesEntireResponse() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".md")
        defer {try? FileManager.default.removeItem(at:url)}
        let text="# Notes\n```python\nprint(1)\n```\n## Final section\nRésumé.\n"
        try MarkdownArtifact.export(text,to:url)
        XCTAssertEqual(try Data(contentsOf:url),Data(text.utf8))
    }
}
