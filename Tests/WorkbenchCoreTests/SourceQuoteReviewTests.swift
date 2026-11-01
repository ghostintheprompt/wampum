import XCTest
@testable import WorkbenchCore

final class SourceQuoteReviewTests: XCTestCase {
    func testChecksQuotedSpansAgainstExactAttachedDrafts() {
        let sources = ["README.md": "## Run locally\n\nnpm run build\n"]
        let answer = "**Source:** README.md\n> npm run build\n\n**Source:** README.md\n> npm run deploy\n"

        let review = SourceQuoteReview(answer: answer, sources: sources)

        XCTAssertEqual(review.findings.map(\.status), [.exactMatch, .notFound])
        XCTAssertEqual(review.findings[0].matchedSources, ["README.md"])
        XCTAssertTrue(review.summary.contains("1 of 2"))
        XCTAssertTrue(review.limitation.contains("does not prove"))
    }

    func testOuterQuotationMarksDoNotTurnAnExactCitationIntoAMismatch() {
        let review = SourceQuoteReview(
            answer: "Source: README.md\n> \"The public build leaves wallet actions offline.\"\n\nSource: CHECK OUTPUT 1\n> “Exit: 0”",
            sources: [
                "README.md": "The public build leaves wallet actions offline.",
                "CHECK OUTPUT 1": "Exit: 0"
            ]
        )
        XCTAssertEqual(review.findings.map(\.status), [.exactMatch, .exactMatch])
        XCTAssertEqual(review.findings.map(\.text), [
            "The public build leaves wallet actions offline.",
            "Exit: 0"
        ])
    }

    func testMatchingQuoteWithoutSourceLabelStillNeedsCitation() {
        let review = SourceQuoteReview(
            answer: "> The public build leaves wallet actions offline.",
            sources: ["README.md": "The public build leaves wallet actions offline."]
        )

        XCTAssertEqual(review.findings.first?.status, .citationMissing)
        XCTAssertEqual(review.findings.first?.matchedSources, ["README.md"])
    }

    func testNestedMarkdownMarkerPreservesLiteralGreaterThanFromCheckOutput() {
        let review = SourceQuoteReview(
            answer: "Source: CHECK OUTPUT 1\n> > coin-droppa@1.1.0 build\n> > node scripts/build-site.js",
            sources: ["CHECK OUTPUT 1": "> coin-droppa@1.1.0 build\n> node scripts/build-site.js"]
        )

        XCTAssertEqual(review.findings.first?.status, .exactMatch)
    }

    func testWrongSourceAttributionIsVisibleEvenWhenQuoteExistsElsewhere() {
        let sources = [
            "README.md": "The preview leaves wallet actions offline.",
            "PUNCHLIST.md": "The transaction flow is not verified."
        ]
        let answer = "**Source:** README.md\n> The transaction flow is not verified."

        let review = SourceQuoteReview(answer: answer, sources: sources)

        XCTAssertEqual(review.findings.first?.status, .sourceMismatch)
        XCTAssertEqual(review.findings.first?.matchedSources, ["PUNCHLIST.md"])
    }

    func testUnattachedCitationIsNotSilentlyAccepted() {
        let review = SourceQuoteReview(
            answer: "**Source:** ARCHITECTURE.md\n> The pool is deployed.",
            sources: ["README.md": "The pool is not deployed."]
        )

        XCTAssertEqual(review.findings.first?.status, .citationNotAttached)
    }

    func testCodeFencesAreNotTreatedAsEvidenceQuotes() {
        let review = SourceQuoteReview(
            answer: "```md\n> fake quoted source\n```\nThis line is ordinary prose.",
            sources: ["README.md": "fake quoted source"]
        )

        XCTAssertTrue(review.findings.isEmpty)
        XCTAssertTrue(review.summary.contains("No blockquoted evidence"))
    }

    func testOlderChatMessagesDecodeWithoutQuoteReviewField() throws {
        let encoded = try JSONEncoder().encode(ChatMessage(role: "assistant", content: "Older reply"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sourceQuoteReview")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(ChatMessage.self, from: legacy)

        XCTAssertEqual(restored.content, "Older reply")
        XCTAssertNil(restored.sourceQuoteReview)
    }
}
