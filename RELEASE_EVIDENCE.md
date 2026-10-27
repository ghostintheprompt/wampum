# v0.1.1 prototype verification

October 26, 2026. Public source assembled from local development commit 3f77f51, excluding private handoffs/history, runtime state and machine-specific client configurations. This public repository starts from a reviewed snapshot. Local checkpoint IDs in README refer to the development record, not commits available in this release history.

Reference machine: Apple M4 Mac mini, 16 GB unified memory, macOS 26.6.2, Apple Swift 6.4. Ollama 0.33.2. Installed model lukey03/Qwen3.5-9B-abliterated:latest, 9B Q4_K_M, completion/tools/thinking, no reported vision.

| Scope | Result |
|---|---|
| Isolated source default suite |93 executed, 86 passed, 7 explicit skips, 0 failures|
| Same source with local-model/browser/controller flags |93 executed, 90 passed, 3 explicit skips, 0 failures|
| Fresh release app build |Passed; all 3 executables bundled|
| App signature verification |Ad-hoc signature verified; no notarization or public binary installer|
| Source privacy selection |No private history/handoff, live state, machine-specific MCP configuration or private case material included|

The default skips comprise optional local services, scenario/profile measurements and the absent sibling-monitor integration. Live flags enable installed Qwen, actual isolated Chrome/Playwright and the real local controller helper. Remaining 3 skips are scenario-memory/profile opt-ins and the absent sibling-monitor integration. The separate original-workspace monitor integration was tested before snapshotting; it is not inferred to run in this checkout.

The live browser check recorded a Qwen click proposal, explicit approval, changed loopback page marker and matching console evidence. The controller check exercised scoped handoff, reviewed observation, queued click, operator execution, status and revocation. No external assistant-provider turn or client engagement was used.

This run's warmed-request cancellation returned in 0.02747 seconds. Following READY completed in 0.3380 seconds. Warmup reported 9.946 seconds of loading. These are short-request observations on this machine, not throughput, peak-memory or long-session benchmarks. Server-side compute-stop timing was not established.

Reproduce:

```sh
swift test
WAMPUM_LIVE_TEST=1 WAMPUM_BROWSER_LIVE=1 WAMPUM_CONTROLLER_LIVE=1 swift test
scripts/build-app.sh
codesign --verify --deep --strict build/Wampum.app
```

Installed services are opt-in. Tests never install a model. Browser dependencies need explicit setup described in README. See STATUS.md for unimplemented work and coverage limits.


## Native QA and 0.1.1 path correction

Native launch after the initial 0.1.0 source cut exposed inconsistent macOS temporary-path aliases. Version 0.1.1 canonicalizes enumerated and resolved paths before relative-path handling. Two new tests pass for `/tmp`/`/private/tmp` roots, Unicode names, readable file listings and safe saves. All default and local-service checks above were rerun against the patched snapshot.

The rebuilt native app then displayed correct relative names, opened a source file through the explorer, discovered Qwen, showed its actual capabilities, presented the frozen request review, and saved the real local READY response. Prompt 185 / output 2 were observed in the app. Screenshot: docs/release-editor.png. Only temporary release state and public source were used; the original work session stayed open.

## Browser transport shutdown — October 27, 2026

MCP now launches in an owned process group. Disconnect closes its pipes, signals the group, allows up to three seconds for graceful shutdown and then escalates to KILL if needed. Natural server exit also cleans remaining group members before reaping its leader. Disconnect waits for tracked shutdowns; repeated calls cannot report completion while an earlier cleanup remains pending. Cancelled callers still wait, and a pending request fails without an automatic retry. Pipe readers own duplicate descriptors and cancellable polling, preventing an old reader from consuming a replacement connection's data.

Two real-process regressions cover TERM-ignoring children/grandchildren, cancelled/repeated Stop, an unaffected unrelated process, replacement connections and natural server exit with inherited pipes. A separate opt-in test opened the installed Playwright adapter and an isolated Chrome instance against an owned loopback fixture: all eight observed transport/browser descendants exited. It made no model call. Native Browser Check and Disconnect were also exercised in a separately identified app with temporary state; the displayed result was `Disconnected. Owned MCP transport stopped.`

This owns the spawned group, not every possible descendant. Deliberate setsid/setpgid escape, reparented helpers outside the observed tree, force quit/power loss and complete OS-level containment remain open. The existing browser profile, network approvals and no-cloud-fallback policy are unchanged.

Repeat the regression with `swift test --filter MCPProcessTests`. The actual browser check is `WAMPUM_BROWSER_LIVE=1 swift test --filter BrowserAppTests.testLiveBrowserTransportDescendantCleanup`; it requires the existing Node/Playwright/Chrome setup and installs nothing.

Fresh-source default run:96total,88passed,8skipped,0failures. The additional local browser cleanup test passed separately. Native review used the signed locally rebuilt source-equivalent app and isolated state. [Native Disconnect result](docs/cleanup-review.png). No notarized installer or new release tag accompanies this main-branch source update.
