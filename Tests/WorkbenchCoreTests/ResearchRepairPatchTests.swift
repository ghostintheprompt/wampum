import XCTest
@testable import WorkbenchCore
final class ResearchRepairPatchTests:XCTestCase {
    func patch(_ edits:[[String:String]])throws->ResearchRepairPatch {
        try JSONDecoder().decode(ResearchRepairPatch.self,from:JSONSerialization.data(withJSONObject:["edits":edits]))
    }
    func testExactEditsPreserveUntouchedSourceAndUnicode()throws {
        let source="α\nleft = 1\nright = 2\nlast\n"
        let edits=try patch([["old":"left = 1","new":"left = 3"],["old":"right = 2","new":"right = 4"]])
        XCTAssertEqual(try edits.applying(to:source,expectedHash:ResearchDocument.digest(source)),"α\nleft = 3\nright = 4\nlast\n")
    }
    func testStaleOrAmbiguousTargetIsRejected()throws {
        let edit=try patch([["old":"x","new":"y"]])
        XCTAssertThrowsError(try edit.applying(to:"x",expectedHash:ResearchDocument.digest("old")))
        XCTAssertThrowsError(try edit.applying(to:"x x",expectedHash:ResearchDocument.digest("x x")))
        XCTAssertThrowsError(try edit.applying(to:"z",expectedHash:ResearchDocument.digest("z")))
    }
    func testOverlappingEditsCannotRewriteEachOther()throws {
        let edit=try patch([["old":"abc","new":"d"],["old":"bc","new":"e"]])
        XCTAssertThrowsError(try edit.applying(to:"abc",expectedHash:ResearchDocument.digest("abc")))
    }
    func testEmptyAndNoOpPatchRejected()throws {
        for entries in [[],[["old":"","new":"x"]],[["old":"x","new":"x"]]] {
            let edit=try patch(entries)
            XCTAssertThrowsError(try edit.applying(to:"x",expectedHash:ResearchDocument.digest("x")))
        }
    }
    func testInvalidPatchRetainsRootDiagnosticAcrossRetries() {
        let original="SyntaxError line 37: missing closing bracket"
        let once=ResearchRepairPatch.rejectionFeedback(previous:original,current:"target missing",draftUnchanged:true)
        let twice=ResearchRepairPatch.rejectionFeedback(previous:once,current:"target ambiguous",draftUnchanged:true)
        XCTAssertTrue(twice.contains(original))
        XCTAssertTrue(twice.contains("target missing"))
        XCTAssertTrue(twice.contains("target ambiguous"))
        XCTAssertEqual(ResearchRepairPatch.rejectionFeedback(previous:twice,current:"Undefined name after syntax repaired",draftUnchanged:false),"Undefined name after syntax repaired")
    }

}
