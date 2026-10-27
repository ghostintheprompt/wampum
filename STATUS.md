# Wampum prototype queue

Personal macOS red-team research/prototype workbench, MIT. Designed on an Apple M4 Mac mini with 16 GB. Early source snapshot, no app account or telemetry uploader.

Implemented: local Ollama, safe saves/checkpoints, scenario memory/rejected-tool state, reviewed single-step browser proposals, image copies/OCR with capability gates, independently saved execution/observation receipts, scoped controller helper, owned command groups, integrity baselines/native panel and unsigned approval/source metadata.

Evidence: default fixture suite, separately opt-in installed-model/browser/controller checks and native UI review. Public release evidence is recorded in RELEASE_EVIDENCE.md after this snapshot is verified. Synthetic/loopback checks do not establish client-engagement outcomes.

Open: deliberately detached/reparented process containment and app-quit/force-quit cleanup; long native sessions and cold-cancellation/queue conditions; streaming output; tabs/search/diffs/LSP/Git/interactive terminal; signed independently anchored provenance; full OS/toolchain/deployment matrix. Direct browser controls without explicit approval records remain unlinked in monitor replay.

No private case data, runtime state, machine-specific MCP config or private handoff history ships in this snapshot. Development timestamps are checkpoints, not continuous working hours.


Version 0.1.1: fixed macOS temporary alias handling found by native QA after the first source cut. Added two alias/Unicode/save regressions. Snapshot totals93 tests; default86 pass/7 skips, local-service90 pass/3 skips. Native file opening/model discovery/reviewed response also verified. See RELEASE_EVIDENCE.md.

October27 source update: owned MCP groups and waited/repeated/cancelled disconnect cleanup implemented. Two process-tree regressions pass. Fresh public suite96total,88pass/8opt-in-or-missing-integration skips,0failures. Separate installed Chrome cleanup test passes with8observed owned processes exiting, no model call. Native local Browser Check/Disconnect reviewed in a separate temporary-state app. See README and RELEASE_EVIDENCE.md for limits. Existing v0.1.1 tag remains a historical release; this is a source update on main.
