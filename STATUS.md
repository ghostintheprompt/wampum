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
# Multi-file project context — 2026-10-31

## Implemented

- Model requests include every open editor tab by default, up to 32,000 UTF-8 source bytes. The request preview shows the actual attached content before send.
- **Include all open editor tabs** can be switched off to send only the current file. **Include open file as default context** can be switched off to omit editor sources.
- Isolated source review continues to exclude chat history and now treats all attached tabs as evidence sources.
- Requests above the source-byte cap stop with a direct error before creating a sendable preview.

## Coin Droppa working-set check

The opt-in local Qwen check attached `README.md`, `PUNCHLIST.md`, and `AGENTS.md` from Coin Droppa and verified that source review excluded the seeded unsupported conversation claim. It returned a proposed portfolio deployment slice, but also named `scripts/build-site.js`, which is absent from the repository, and contradicted its own source evidence by recommending transaction flow while describing a wallet-offline preview. This is a concrete remaining model-quality gap: Wampum delivered the selected sources, but Qwen did not reliably reconcile them or validate proposed paths. The generated response is preserved at `/private/tmp/Wampum-CoinDroppa-Evaluation/coin-droppa-multifile-response.txt`; it is a model output, not a verified release plan.

## Verification

- `swift test --filter AppTests`: 105 app tests, 13 opt-in skips, 0 failures.
- `swift test`: 105 app tests, 13 opt-in skips, 0 failures; core tests also passed.
- `scripts/build-app.sh` produced `build/Wampum-QA2.app` with a separate bundle identifier.
- Launched the fresh QA app using a separate Wampum QA 2 instance. Its rendered UI showed **Include all open editor tabs** checked and reported “Attaches all 2 open drafts, up to 32 KB total.” Existing Wampum state was not used.
- `git diff --check` passed before final review.
- Push status: pending.
