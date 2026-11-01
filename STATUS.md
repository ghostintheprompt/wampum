# Wampum status — 2026-10-31

## Working baseline

The complete public Wampum source is restored on `main`, tracking `origin/main` at `6c6281a`. The interrupted local merge state is preserved outside the repo at `/private/tmp/wampum-interrupted-recovery-20261031/`; the previous known-good feature commit is `900abb9` on `tools-pentest-orchestration`.

## This recovery

- Normal Qwen chat retains prior conversation and the open editor.
- **Isolate source review (exclude chat history)** is an explicit option for source audits. It attaches the open editor and current request without earlier chat turns.
- The opt-in Coin Droppa live test reads the clean release README and saves its exact request/response outside the repository. Qwen's response was returned and saved; manual comparison found unsupported claims and missed release details.
- Stale, untracked status/punchlist snapshots were moved out of the repo and retained with the recovery backup.

## Verification

The default Swift suite last passed with 273 core tests and 104 app tests, 16 opt-in skips, and no failures. `scripts/build-app.sh` produced the release app and a separate QA app. The QA app launched against disposable state; its interface showed the source-review toggle unchecked by default and disabled until a file is open. The local Qwen trial against the release README completed. It correctly reported the local start command and some privacy/revenue limits, but invented a withdrawal-triggered board animation and per-play fees, overstated that privacy is unimplemented, and missed the offline portfolio-build details. Passing transport or fixture tests does not establish model answer accuracy.

## Remaining work

1. Verify both normal chat and isolated source review through the QA app's native request preview.
2. Add an output-side citation check that verifies quoted spans against the exact attached draft and flags unsupported quotes. It must not label semantic claims as proven.
3. Rerun the fixed Coin Droppa release task after each change and record failures before changing prompts or model settings.
