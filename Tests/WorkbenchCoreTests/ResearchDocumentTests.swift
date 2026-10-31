import XCTest
@testable import WorkbenchCore
final class ResearchDocumentTests:XCTestCase {
    func testAssemblyRejectsReplacedFrozenProgramEvenWithMatchingReceipt() throws {
        let program="import unittest\n# def test_one\n# def test_two\n# def test_three\nvalue = 1"
        let changed=program.replacingOccurrences(of:"value = 1",with:"value = 2")
        let chapter=ResearchChapter(title:"Frozen chapter",source:"Reference",url:"https://example.test",codeProgram:program)
        func section(_ code:String)throws->ResearchSection {
            let body="## Mechanism\n"+String(repeating:"An explanatory sentence about this local fixture. ",count:40)+"\n## Examples\n```python\n"+code+"\n```\n## Defense\nBounded fixture.\n## Verification\nRecorded check."
            // A matching receipt and body hash must not override the manifest's
            // frozen program. This fixture tests integrity, not Python execution.
            let receipt:[String:Any]=["tests":3,"failures":0,"errors":0,"skipped":0,"codeSHA256":ResearchDocument.digest(code+"\n")]
            let log="VERIFIED_RECEIPT "+String(decoding:try JSONSerialization.data(withJSONObject:receipt),as:UTF8.self)
            return ResearchSection(title:chapter.title,sourceHash:ResearchDocument.digest(chapter.source),body:body,stopReason:"stop",outputTokens:10,checkLog:log,checked:true)
        }
        XCTAssertNoThrow(try ResearchDocument.assemble(title:"Workbook",chapters:[chapter],sections:[section(program)]))
        XCTAssertThrowsError(try ResearchDocument.assemble(title:"Workbook",chapters:[chapter],sections:[section(changed)]))
    }

    func testReviewRejectsProgramThatDiffersFromFrozenManifest() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let program="import unittest\n# def test_one\n# def test_two\n# def test_three\nvalue = 2\n"
        let chapter=ResearchChapter(title:"Frozen chapter",source:"Reference",url:"https://example.test",codeProgram:program.replacingOccurrences(of:"value = 2",with:"value = 1").trimmingCharacters(in:.newlines))
        let object:[String:Any]=["title":"Workbook","model":"local","requirements":[],"chapters":[try JSONSerialization.jsonObject(with:JSONEncoder().encode(chapter))]]
        let manifest=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        try manifest.write(to:root.appendingPathComponent("manifest.json"))
        try Data(program.utf8).write(to:root.appendingPathComponent("exercise.py"))
        let body="## Mechanism\n"+String(repeating:"An explanatory sentence about this local fixture. ",count:40)+"\n## Examples\n```python\n"+program+"```\n## Defense\nBounded fixture.\n## Verification\nRecorded check."
        let candidate=ResearchCandidate(chapter:0,title:chapter.title,sourceHash:ResearchDocument.digest(chapter.source),manifestHash:ResearchDocument.digest(String(decoding:manifest,as:UTF8.self)),body:body,stopReason:"stop",outputTokens:10,codeFile:"exercise.py",codeHash:ResearchDocument.digest(program),attempt:1)
        XCTAssertThrowsError(try candidate.reviewedCode(work:root))
    }

    func testSelectedPathsRemainOneLiteralShellArgument() throws {
        let value="folder's name; printf INJECTED $(printf EXTRA)"
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/zsh");process.arguments=["-c","printf %s "+ResearchDocument.shellQuote(value)];process.standardOutput=pipe
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0);XCTAssertEqual(String(decoding:data,as:UTF8.self),value)
    }
    func testApprovalCannotTransferToChangedCodeOrJob() {
        let candidate=ResearchCandidate(chapter:0,title:"Chapter1",sourceHash:"source",manifestHash:"job",body:"draft",stopReason:"stop",outputTokens:10,codeFile:"exercise.py",codeHash:"code",attempt:1)
        let approval=ResearchApproval(candidate);XCTAssertTrue(approval.matches(candidate))
        var changed=candidate;changed.codeHash="different";XCTAssertFalse(approval.matches(changed))
        changed=candidate;changed.manifestHash="different";XCTAssertFalse(approval.matches(changed))
        changed=candidate;changed.id="different";XCTAssertFalse(approval.matches(changed))
        changed=candidate;changed.body="Unreviewed prose";XCTAssertFalse(approval.matches(changed))
    }
    func testReviewedCandidateRejectsChangedBytesAndEscapingPaths() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source="Observed local reference",title="Chapter1"
        let object:[String:Any]=["title":"Workbook","model":"local","requirements":[],"chapters":[["title":title,"source":source,"url":"https://example.test"]]]
        let manifest=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);try manifest.write(to:root.appendingPathComponent("manifest.json"))
        let program="""
        import unittest
        
        def can_read(user,record):
            return user['tenant']==record['tenant'] and user['id']==record['owner']
        
        class AccessTests(unittest.TestCase):
            def test_same_tenant_owner(self):
                self.assertTrue(can_read({'tenant':'A','id':7},{'tenant':'A','owner':7}))
            def test_other_tenant(self):
                self.assertFalse(can_read({'tenant':'A','id':7},{'tenant':'B','owner':7}))
            def test_other_owner(self):
                self.assertFalse(can_read({'tenant':'A','id':7},{'tenant':'A','owner':8}))
        
        if __name__=='__main__':
            unittest.main()
        """+"\n"
        let body="## Mechanism\n"+String(repeating:"This synthetic fixture checks a tenant and owner boundary.\n",count:35)+"## Examples\n```python\n"+program+"```\n## Defense\nTenant and owner must both match.\n## Verification\nThree known cases, no external target."
        try Data(program.utf8).write(to:root.appendingPathComponent("exercise.py"))
        var candidate=ResearchCandidate(chapter:0,title:title,sourceHash:ResearchDocument.digest(source),manifestHash:ResearchDocument.digest(String(decoding:manifest,as:UTF8.self)),body:body,stopReason:"stop",outputTokens:100,codeFile:"exercise.py",codeHash:ResearchDocument.digest(program),attempt:1)
        XCTAssertEqual(try candidate.reviewedCode(work:root),program)
        try Data((program+"# changed\n").utf8).write(to:root.appendingPathComponent("exercise.py"))
        XCTAssertThrowsError(try candidate.reviewedCode(work:root))
        candidate.codeFile="../outside.py";XCTAssertThrowsError(try candidate.reviewedCode(work:root))
    }
    func testMissingChaptersCannotProduceFinalArtifact() throws {
        let chapter=ResearchChapter(title:"Chapter1",source:"Observed reference",url:"https://example.test")
        XCTAssertThrowsError(try ResearchDocument.assemble(title:"Report",chapters:[chapter],sections:[]))
    }
    func testModelSuccessTextIsNotAnExecutionReceipt() {
        XCTAssertThrowsError(try ResearchDocument.verifyReceipt("All tests passed.100%success",code:"print(1)"))
    }
    func testReceiptMustMatchExactCurrentCodeAndPassingCounts() throws {
        let code="print(1)\n"
        let data:[String:Any]=["tests":3,"failures":0,"errors":0,"skipped":0,"codeSHA256":ResearchDocument.digest(code)]
        let log="VERIFIED_RECEIPT "+String(decoding:try JSONSerialization.data(withJSONObject:data),as:UTF8.self)
        XCTAssertNoThrow(try ResearchDocument.verifyReceipt(log,code:code))
        XCTAssertThrowsError(try ResearchDocument.verifyReceipt(log,code:"print(2)\n"))
    }
    func testNaturalStopDoesNotCertifyACompleteSection() {
        XCTAssertThrowsError(try ResearchDocument.validate("Complete. Saved to Downloads.",reason:"stop"))
        XCTAssertThrowsError(try ResearchDocument.validate(String(repeating:"Still generating\n",count:200),reason:"length"))
    }
    func testStructuredSectionRendersOneProgramWithoutTruncatingNestedText() throws {
        let payload:[String:String] = ["mechanism":"Boundary", "examples":"Two cases", "defense":"Reject untrusted input", "verification":"Await actual checks", "python":"print(\"α\")\n"]
        let section=try JSONDecoder().decode(ResearchGeneratedSection.self,from:JSONSerialization.data(withJSONObject:payload))
        XCTAssertTrue(section.markdown.contains("```python\nprint(\"α\")\n\n```"))
        XCTAssertTrue(section.markdown.hasSuffix("Await actual checks"))
        XCTAssertThrowsError(try JSONDecoder().decode(ResearchGeneratedSection.self,from:Data("{}".utf8)))
    }
    func testStreamCheckpointRetainsExactUnicodeAndRefusesOverwrite() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("partial.json")
        let checkpoint=try StreamCheckpoint(url:path)
        _=try checkpoint.append("First α\n")
        _=try checkpoint.append("Last β")
        try checkpoint.finish()
        XCTAssertEqual(try String(contentsOf:path),"First α\nLast β")
        XCTAssertThrowsError(try checkpoint.append("lost"))
        XCTAssertThrowsError(try StreamCheckpoint(url:path))
    }

    func testRepairCannotDropRequiredSectionOrAddUncheckedBlock()throws {
        let body="## Mechanism\nA\n## Examples\n```python\nprint(1)\n```\n## Defense\nB\n## Verification\nC\n"
        XCTAssertEqual(try ResearchDocument.validateRepairShape(body),"print(1)\n")
        XCTAssertThrowsError(try ResearchDocument.validateRepairShape(body.replacingOccurrences(of:"## Defense",with:"")))
        XCTAssertThrowsError(try ResearchDocument.validateRepairShape(body+"```python\nprint(2)\n```\n"))
    }
    func testProgramPayloadFencesAndHeadingsCannotTruncateDocument()throws {
        let python="payload = \"\"\"\n```system\n## Defense\n```\n\"\"\"\nprint(payload)"
        let data:[String:String]=["mechanism":"A","examples":"B","defense":"C","verification":"D","python":python]
        let section=try JSONDecoder().decode(ResearchGeneratedSection.self,from:JSONSerialization.data(withJSONObject:data))
        XCTAssertTrue(section.markdown.contains("````python"))
        XCTAssertEqual(try ResearchDocument.validateRepairShape(section.markdown),python+"\n")
        XCTAssertTrue(section.markdown.hasSuffix("D"))
    }

    func testFrozenProgramAndProseBriefSurviveManifestRoundTrip()throws {
        let chapter=ResearchChapter(title:"Chapter1",source:"Full original source",url:"https://example.test",codeProgram:"print(1)",codeAttribution:"Recorded model output",proseFacts:"Observed facts only")
        let restored=try JSONDecoder().decode(ResearchChapter.self,from:JSONEncoder().encode(chapter))
        XCTAssertEqual(restored.source,"Full original source")
        XCTAssertEqual(restored.proseFacts,"Observed facts only")
        XCTAssertNoThrow(try restored.validateFrozenProgram("print(1)\n"))
        XCTAssertThrowsError(try restored.validateFrozenProgram("print(2)\n"))
        let legacy=try JSONDecoder().decode(ResearchChapter.self,from:Data(#"{"title":"Old","source":"Original","url":"https://example.test"}"#.utf8))
        XCTAssertNil(legacy.codeProgram)
        XCTAssertNoThrow(try legacy.validateFrozenProgram("legacy code"))
    }

    func testPreparedProseRejectsLongButCutOffExample()throws {
        let sentence=String(repeating:"Observed protocol behavior is bounded by the actual checked fixtures. ",count:3)
        var fields:[String:Any]=["mechanism":sentence,"examples":sentence,"defense":sentence,"verification":sentence]
        XCTAssertNoThrow(try ResearchProseSection.validate(fields))
        fields["examples"]=String(repeating:"Long example description ",count:6)+"build_chat_request('{"
        XCTAssertThrowsError(try ResearchProseSection.validate(fields))
        fields["examples"]="Complete."
        XCTAssertThrowsError(try ResearchProseSection.validate(fields))
    }

    func testLegacyApprovalWithoutChapterBindingRequiresFreshReview()throws {
        let candidate=ResearchCandidate(chapter:0,title:"Chapter1",sourceHash:"source",manifestHash:"job",body:"reviewed text",stopReason:"stop",outputTokens:10,codeFile:"exercise.py",codeHash:"code",attempt:1)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(ResearchApproval(candidate))) as? [String:Any])
        legacy.removeValue(forKey:"bodyHash")
        let approval=try JSONDecoder().decode(ResearchApproval.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertFalse(approval.matches(candidate))
    }

    func testProseCannotHideExecutableTestsOutsideCheckedProgram()throws {
        let sentence="This paragraph explains the observed local program and its limits without claiming a live external result."
        var fields:[String:Any]=["mechanism":sentence,"examples":sentence,"defense":sentence,"verification":sentence]
        XCTAssertNoThrow(try ResearchProseSection.validate(fields))
        for code in ["import unittest", "from unittest import TestCase", "class HiddenTests(unittest.TestCase):", "def test_hidden(self):", "@unittest.expectedFailure"] {
            fields["verification"]=sentence+"\n"+code+"\nThis must remain in the checked program."
            XCTAssertThrowsError(try ResearchProseSection.validate(fields))
        }
        fields["verification"]="The word import occurs in ordinary explanatory prose and does not make this sentence executable Python."
        XCTAssertNoThrow(try ResearchProseSection.validate(fields))
    }

}
