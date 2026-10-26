import XCTest
@testable import WorkbenchCore
final class PrivacyTests:XCTestCase {
    func testExactAliasesAcrossOccurrences()throws{let m=try ContentMasker(rules:"Client Example => CLIENT_A",detectSecrets:false);let r=m.mask("Client Example / Client Example");XCTAssertEqual(r.text,"CLIENT_A / CLIENT_A");XCTAssertEqual(r.replacements,2)}
    func testAliasesDoNotCascade()throws{let m=try ContentMasker(rules:"alpha => beta\nbeta => gamma",detectSecrets:false);XCTAssertEqual(m.mask("alpha beta").text,"beta gamma")}
    func testLongestAndUnicode()throws{let m=try ContentMasker(rules:"éclair client => CLIENT\néclair => FOOD",detectSecrets:false);XCTAssertEqual(m.mask("éclair client / éclair").text,"CLIENT / FOOD")}
    func testBearerAndAssignment()throws{let r=try ContentMasker().mask("Authorization: Bearer ABCDEFGHIJKLMNOP\napi_key=ABCDEF123456\npassword='privatevalue'");XCTAssertFalse(r.text.contains("ABCDEFGHIJKLMNOP"));XCTAssertFalse(r.text.contains("ABCDEF123456"));XCTAssertFalse(r.text.contains("privatevalue"));XCTAssertEqual(r.replacements,3)}
    func testPrivateKey()throws{let r=try ContentMasker().mask("-----BEGIN PRIVATE KEY-----\nSYNTHETIC\n-----END PRIVATE KEY-----");XCTAssertEqual(r.text,"[SECRET_MASKED]")}
    func testOrdinaryCodeUnchanged()throws{let s="func add(a: Int, b: Int) -> Int { a + b }";XCTAssertEqual(try ContentMasker().mask(s).text,s)}
    func testInvalidAndDuplicateRulesRejected(){XCTAssertThrowsError(try ContentMasker(rules:"invalid"));XCTAssertThrowsError(try ContentMasker(rules:"a => b\na => c"));XCTAssertThrowsError(try ContentMasker(rules:" => alias"))}
    func testPrivacySettingsDefaultsAndRoundTrip()throws{let r=try JSONDecoder().decode(PrivacySettings.self,from:Data("{}".utf8));XCTAssertTrue(r.maskModelRequests);XCTAssertTrue(r.maskExternalURLs);let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)};let store=PrivacyStore(directory:root);var p=PrivacySettings();p.aliasRules="a => b";p.proxyURL="socks5://127.0.0.1:1080";try store.save(p);XCTAssertEqual(try store.load().aliasRules,p.aliasRules)}
}
