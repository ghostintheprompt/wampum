Source and development history: [github.com/ghostintheprompt/wampum](https://github.com/ghostintheprompt/wampum). Local sessions, private research, credentials, and generated output stay out of Git through `.gitignore`.

# Wampum

![Wampum artwork: Rockaway marshes, wampum, and jets over Kennedy Airport](Resources/WampumIcon.png)

A native macOS workbench for **local, offline AI-assisted security research and prototyping**, where the local model is treated as untrusted and every change it proposes is gated before it touches your project. Built for a Mac mini M4 with 16 GB unified memory, running a model entirely on-device through local Ollama. No third-party Swift packages.

Michael's name for the project comes from finding wampum in the mud and reeds near Kennedy Airport growing up.

## What it is, and what it isn't

**It is** a local-first, air-gapped-by-default workbench. The model runs on your Mac; nothing leaves the machine unless you grant it, one run at a time. That makes it suited to confidential work — engagements and data that legally cannot go to a cloud model.

**It isn't** a local stand-in for a frontier model. A small local model (Qwen and the like) hallucinates and will hand back malformed or wrong output. Wampum's value is not the model's intelligence — it's the **gate** around it. The model proposes; nothing it produces reaches your files, your network, or a report without passing review.

## The core loop

Open a project, write a Markdown brief or edit a file, and ask for a change. The model returns a complete file replacement or a unified diff. **Review Patch** validates it; **Apply Reviewed Patch** writes it only after you approve, backing up every original first. Malformed output is kept in the transcript and changes nothing on disk.

- **Build from MD** gathers a saved brief plus prioritized project source (entrypoints and manifests first, vendored/generated/lockfiles skipped), previews the exact request, caps attached text at 84 KB, and selects the 32K context profile. Starting profile is 8K, with 4K/16K/32K options.
- For ordinary questions, only the active editor file is attached by default; extra tabs and source-only review are opt-in.

## The gate — why the model's output can't hurt you

- **Patch review** rejects renames, binaries, symlinks, `.git` and `.env` paths, and any diff that doesn't apply cleanly; it backs up changed originals locally and never runs the proposed code.
- **Model client** talks only to localhost Ollama and refuses HTTP redirects.
- **Network guard** is local by default: direct outbound sockets are restricted until an explicit one-run grant.
- **Content masking** and a **separate, opt-in proxy** that only the inspection tool uses — Ollama, shell, browser and MCP never inherit it.
- **Source-quote review** is an exact-text citation check: it verifies Markdown blockquotes against frozen source text and flags anything missing or misattributed. It checks quotes, not truth.
- **Checkpoints**, **editor-tab draft recovery**, and **Close Project** for a clean workspace boot.

## Security tooling (authorized engagements)

All of it routes through one discipline: a per-case **authorized scope** (the rules of engagement), operator review, owned process groups, and hashed receipts. With no scope declared, every outward action fails closed.

- **Hypothesis → Finding evidence path.** A ledger claim promotes to a finding only when it is operator-approved, references a host-captured receipt that still verifies byte-for-byte, and passes the finding gate with no blockers. A model assertion, a scanner lead, or a tampered receipt cannot promote. Severity and impact are the operator's call, never the tool's.
- **Scope-gated tools:** Docker control; Burp Suite over loopback REST; recon (nmap/ffuf/subfinder) whose leads are scored — ffuf results demote the catch-all/soft-404 bucket, subdomain enum feeds a **takeover classifier** that grades a dangling CNAME by reclaimability (an unclaimed GitHub Pages/S3/Heroku target is a strong lead; an AWS ELB / DigitalOcean random-name target is DNS hygiene, not a takeover). A request replayer runs a **BOLA/IDOR object-ID sweep and an identity matrix, confidence-tiered**: an unauthorized read byte-identical to an owner's is a strong lead, while an empty or shared/boilerplate 2xx is demoted to weak. Plus an **authorization-persistence** (temporal) check, Semgrep source-review import, and **monitor-mode 802.11 wireless capture** in a Kali UTM guest — one-click VM detect + a preflight doctor (guest reachable, Alfa visible, driver/interface up), with Wampum custodying the hashed evidence.
- **AI/LLM red-team suite** (evaluators for authorized targets, not weapons): indirect prompt injection and tool weaponization, RAG context contamination, excessive agency, cross-session memory-persistence leaks, multimodal/OCR-layer injection, guardrail-robustness measurement, a defensive agent guard, and a closed-loop attack-graph orchestrator. An **agentic data-exfiltration harness** builds indirect-injection payloads (zero-click markdown-image beacons, tool-send, subdomain/base64 encodings), detects sink-exfil vs reply-channel leaks, and scores reproducibility against the ≥50% bar real agentic-injection programs require.
- **FindingGate** is a deterministic lint that blocks the tells of a premature "finding" — self-assigned severity/CVSS, invented taxonomy, bounty theatre, breach name-drops, and impact narrated as fact — so an over-claimed report or disclosure email can't ship as a finding.

**Honesty boundary.** The access-control, recon and takeover **classifiers are unit-tested and validated against real public-program recon data** gathered read-only/passively (e.g. correctly demoting 25/25 WAF-uniform paths and 114 non-reclaimable dangling CNAMEs to weak). The active authenticated HTTP tools are proven against loopback fixtures, not yet driven against live external targets. The AI cores are tested; the live agentic path is operator-driven and not yet run. **The wireless capture is verified end-to-end against an operator-owned network** — monitor mode engaged, real 802.11 frames written to a hashed pcap. A fixture, loopback, or owned-network pass is not a client engagement; runs against real in-scope targets are operator-driven, and nothing is reported that the evidence path has not promoted.

## Build and launch

Requires macOS 14+, Xcode command-line tools, Swift, and local Ollama for model use.

```sh
swift test            # the Swift suite passes with zero failures
scripts/build-app.sh
open build/Wampum.app  # locally ad-hoc signed; not notarized or App Store distributed
```

Build an isolated instance with its own identity and state, to run beside the main app:

```sh
WAMPUM_APP_OUTPUT="$PWD/build/Wampum-B.app" \
WAMPUM_APP_NAME="Wampum B" \
WAMPUM_BUNDLE_ID=com.ghostintheprompt.wampum.b \
WAMPUM_STATE_DIR="$HOME/Library/Application Support/Wampum-B" \
scripts/build-app.sh
```

## Local state and privacy

State lives at `~/Library/Application Support/Wampum/` — session JSON, checkpoints, file backups, command logs — in plaintext, and holds your work. `WAMPUM_STATE_DIR` redirects it. No sign-in, no analytics SDK, no telemetry. Project edits happen only through Save; checks run under your ordinary macOS account.

## Honest limitations

- The local model can be **wrong or malformed**. In a live QA run Qwen returned malformed diffs twice, once with a behavior change; the gate rejected both and the project stayed byte-for-byte unchanged. That verifies the gate, not the model's accuracy, which is not benchmarked here.
- The runner restricts direct outbound sockets to loopback via `sandbox-exec`, but it is **not** a general security sandbox, a PTY, or process-tree containment; detached children can escape, and force-quit can leave commands alive.
- This is a prototype: ad-hoc signed, not notarized, not distributed.

---

Detailed verification notes and the dated build record live in [`RELEASE_EVIDENCE.md`](RELEASE_EVIDENCE.md) and the Git history.
