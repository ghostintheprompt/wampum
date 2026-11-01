# Wampum punch list

## In progress

- [x] Run the opt-in local Qwen review against Coin Droppa's release README and save request/response outside Git. Qwen got the local run instructions and several limits right, but invented a withdrawal animation and per-play fees, overstated the privacy implementation gap, and missed offline portfolio-build details.
- [x] Build the release app and a separate QA app. Launch QA with disposable state; confirm the new source-review toggle is visible, off by default, and disabled until an editor file is open.
- [ ] Use the QA app's request preview to confirm normal chat retains history and isolated review omits it while including the editor source.

## Accuracy work

- [ ] Add a deterministic output check that extracts quoted evidence and confirms each quote appears in the exact attached source text.
- [ ] Show unsupported or altered quotes beside the response. Describe this as quote validation, not fact verification.
- [ ] Create fixed release-review cases from Coin Droppa README and punch list, with expected facts, explicit unknowns and prohibited inferences.
- [ ] Measure Qwen on those cases before changing prompts, sampling settings or context size; preserve each failed output.

## Release hygiene

- [ ] Run `swift test` and `git diff --check` after the accuracy work.
- [ ] Review the native app's request preview, persistence, and source-review toggle behavior.
- [ ] Refresh this file and `STATUS.md` from verified results; do not claim accuracy based on successful request transport.
# Wampum follow-up — multi-file context

- [x] Include all open editor tabs by default in model requests.
- [x] Keep current-file-only and no-editor-source options one toggle away.
- [x] Preserve the reviewed request preview and isolated source-review mode across multiple files.
- [x] Enforce a 32 KB source-size cap with a clear pre-send error.
- [x] Exercise default all-tabs, current-only override, history exclusion, and oversized-source behavior in app tests.
- [x] Run a Coin Droppa local Qwen review with README, punchlist, and repo instructions attached.
- [x] Run the complete Swift suite and build/launch a fresh QA app.
- [ ] Commit and push the Wampum fix.

Finding from the live run: multi-file context solved the missing-source problem, but the response still proposed an absent `scripts/build-site.js` and conflicted with the documented wallet-offline portfolio scope. Treat generated file plans as suggestions until checked against the repository and its release gates.
