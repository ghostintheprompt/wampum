# Wampum — November 5, 2026

## Focus

Wampum as a working red-team + defensive tool, audited live against real bug-bounty programs and an operator-owned RF lab. Bounties are the audit harness; the deliverable is a correct, intuitive tool. The earlier Coin Droppa patch-workflow acceptance task is no longer the active focus; the patch/gate path it built remains and is unchanged.

## Shipped + verified this session

- [x] UI: 3 surfaces (Editor/Browser/Tools) + System overflow; Tools panel wrapped in a ScrollView (lower sections were clipped/unreachable); military/terminal palette (gunmetal + gleaming tactical green).
- [x] FindingGate hardened: blocks the overclaiming disclosure-email path (asserted takeover + broadened severity). Suite green.
- [x] BOLA/IDOR sweep + identity matrix: confidence tiers (strong = owner-identical bytes; weak = empty/boilerplate 2xx). Validated on passive recon of Klaviyo + Internet Brands.
- [x] Recon: ffuf lead scoring (soft-404/catch-all demoted); scope-gated subfinder orchestration; SubdomainImport + TakeoverProbe (dangling-CNAME reclaimability classifier). Validated: 25/25 Klaviyo WAF paths + 114 IB danglers correctly weak.
- [x] Agentic-exfil harness: indirect-injection payloads (zero-click image, tool-send, subdomain/base64), sink-vs-reply detection, >=50% reliability scoring, live-capture from the sink log. Unit-tested.
- [x] Object-ID sweep identities persist per case (configure once).
- [x] Wireless: VM auto-detect (utmctl list) + one-click preflight doctor; launch-UTM + resilient start (retries the -1712 AppleEvent timeout). VERIFIED end-to-end on an operator-owned network (IsolaTiberina): monitor mode, 186 real 802.11 frames to a hashed pcap.
- [x] Kali VM login reset (forgotten pw); README updated accurately; all pushed to origin.

## Open — next session

### Bounties (audit the tool)
- [ ] OpenAI Safety agentic-exfil (limit-blocked): get accepted on the Bugcrowd Safety program; run S2 (zero-click session exfil) live when ChatGPT Agent access/limit resets. Rig ready in `bug_bounty/openai-safety/` (sink + cloudflared tunnel + inject pages + submission templates).
- [ ] Klaviyo BOLA (operator creds needed): create 2 test accounts, drop keys + profile IDs into the Object-ID Sweep, run the authenticated cross-tenant sweep. Contract + `sweep_targets.md` ready in `bug_bounty/klaviyo/`.
- [ ] Prospect younger / lower-competition Bugcrowd programs for no-signup takeover + exposed-surface. Klaviyo + Internet Brands came back clean — mature programs are poor no-signup EV.

### Tool hardening
- [ ] Active authenticated HTTP path is still only loopback-proven — a live authenticated run (Klaviyo or an owned target) is the next real validation.
- [ ] Wire subfinder output -> auto-run TakeoverProbe/SubdomainImport ranking in-app (the chain is coded; the in-app auto-pipeline isn't fully wired).
- [ ] Run the IsolaTiberina capture through the full in-app wireless flow (import contract -> Run Authorized Wireless Capture -> pcap + manifest pinned as case evidence), not just the direct guest script.
- [ ] Guest-exec reliability: utmctl exec is intermittently flaky (OSStatus -10004 noise, occasional empty returns); password-write commands (chpasswd/usermod) can jam on a stale /etc/.pwd.lock. If Wampum automates guest admin, add lock-clear + retry.

### UI/UX
- [ ] Gleam/HUD polish: thin accent borders on panels (framed-console look).
- [ ] Tools panel is still one long scroll of ~13 sections — sub-tabs (Recon / Access / AI / Wireless / Findings) would finish the navigation fix.

## Verification boundary (honest)

Classifiers (BOLA/identity/recon/takeover) are unit-tested + validated on real passive recon data. Active authenticated HTTP tools are loopback/fixture-proven, not yet driven against a live external target. AI cores tested; the live agentic path is operator-driven and not yet run. Wireless capture is verified live on an operator-owned network. Nothing is reported that the evidence path has not promoted.
