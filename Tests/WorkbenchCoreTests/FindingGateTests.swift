import XCTest
@testable import WorkbenchCore

/// Measures the FindingGate against the three real Wampum outputs for the Giggle
/// case (all false positives at increasing fluency) and one honest research note
/// (a true negative). The gate must block all three attempts and leave the note
/// alone. These are synthetic, host-authored fixtures; they establish lint
/// behaviour, not the truth of any security claim.
final class FindingGateTests: XCTestCase {
    private func rules(_ v: FindingGate.Verdict) -> Set<String> { Set(v.issues.map(\.rule)) }

    // Attempt 1: asserts everything as fact. Invented technique, CVSS, placeholder CVE, report framing.
    func testAttemptOneBlocked() {
        let text = """
        This is a known Flash injection technique. CVSS Score: 7.5 (High).
        CVE-2024-XXXXX (provisional). The flash_channel_id parameter allows full frontend takeover.
        ## VULNERABILITY REPORT: Flash Injection
        """
        let v = FindingGate.review(text)
        XCTAssertTrue(v.blocked)
        XCTAssertTrue(rules(v).isSuperset(of: ["self-assigned-cve", "severity-without-poc", "premature-report-framing", "invented-technique"]))
    }

    // Attempt 2: better words, still asserts the precondition as fact. Bounty, breach name-drops, no taxonomy.
    func testAttemptTwoBlocked() {
        let text = """
        The flash_channel_id parameter builds a script source pointing to attacker-controlled content.
        The script can read sessionStorage and make authenticated API calls; every action the victim takes goes through your hands.
        Why This Is Critical: fintech domains are high-value. This is exactly the kind of vulnerability that leads to major breaches (Equifax, LinkedIn, Facebook).
        Bounty Value: $10,000-$50,000 on HackerOne for authenticated code execution.
        """
        let v = FindingGate.review(text)
        XCTAssertTrue(v.blocked)
        XCTAssertTrue(rules(v).isSuperset(of: ["severity-without-poc", "bounty-estimate", "breach-namedrop", "no-taxonomy", "asserted-impact"]))
    }

    // Attempt 3: learned the structure, but still stamps Critical, keeps "Flash injection", frames as a report.
    func testAttemptThreeStillBlocked() {
        let text = """
        ## VULNERABILITY REPORT: Flash Injection / Authenticated XSS
        ### OBSERVED BEHAVIOR (VERIFIED)
        Parameter flash_channel_id changes rendered frontend content.
        ### HYPOTHESIS (UNVERIFIED - REQUIRES AUTHORIZED TESTING)
        The parameter controls a script source that loads into the origin.
        ### DECIDING UNKNOWN
        Does the parameter reach the browser's script context? This has not been tested.
        ### SEVERITY
        **Critical** — if hypothesis is confirmed, this enables full account takeover.
        """
        let v = FindingGate.review(text)
        XCTAssertTrue(v.blocked)
        XCTAssertTrue(rules(v).isSuperset(of: ["severity-on-unverified", "premature-report-framing", "invented-technique"]))
    }

    // Attempt 4 (the gap found in the live giggle run): a disclosure EMAIL that avoids the words
    // "CVSS"/"severity" and the asserted-impact markers, so it slipped past the gate — while
    // narrating full account takeover, fund transfer, PII access and session-token reuse as fact.
    func testDisclosureEmailOverclaimBlocked() {
        let text = """
        Hello, I am a security researcher reporting a critical security vulnerability responsibly.
        I have discovered an authenticated cross-site scripting (XSS) vulnerability in flash.example.com.
        Impact: Full account takeover without credential theft — the attacker can extract and reuse the
        victim's session token, make unauthorized API calls as the victim (modify bank details, transfer
        funds, read PII), and use the trusted domain for phishing. Same vector as Equifax and LinkedIn.
        """
        let v = FindingGate.review(text)
        XCTAssertTrue(v.blocked, "Overclaiming disclosure email was not blocked: \(rules(v))")
        XCTAssertTrue(rules(v).isSuperset(of: ["asserted-takeover", "severity-without-poc"]),
                      "Missing expected blockers: \(rules(v))")
    }

    // The same impact claims, but honestly framed as unverified, must NOT be blocked by the new rule.
    func testUnverifiedImpactNotBlockedByTakeoverRule() {
        let text = """
        Observed (verified): the flash_channel_id parameter changes rendered content in my own session.
        Hypothesis (unverified, requires authorized testing): if it reaches a script context, account
        takeover via session-token reuse (CWE-79) could follow. Not tested; not a finding yet.
        """
        let v = FindingGate.review(text)
        XCTAssertFalse(rules(v).contains("asserted-takeover"),
                       "Takeover rule fired on an honestly-framed hypothesis: \(rules(v))")
    }

    // True negative: an honest research note. Observed vs hypothesis separated, real taxonomy,
    // no severity, no CVE, no bounty. The gate must NOT cry wolf here.
    func testHonestResearchNotePasses() {
        let text = """
        Observed (verified): the flash_channel_id parameter changes the rendered frontend in my own session.
        Hypothesis (unverified, requires authorized testing): if the value reaches a script context in origin, reflected XSS (CWE-79) could follow.
        Deciding unknown: whether the parameter reaches a script context. Not tested.
        Status: not a finding until demonstrated with a benign marker in authorized scope.
        """
        let v = FindingGate.review(text)
        XCTAssertFalse(v.blocked, "Honest research note was blocked: \(v.issues.map(\.rule))")
        XCTAssertTrue(v.issues.isEmpty, "Unexpected flags on a clean note: \(v.issues.map(\.rule))")
    }
}
