# Wampum status — November 1, 2026

## Current build

- Default requests include the active editor file. Additional editor tabs and source-only review are optional context settings, collapsed and off at launch.
- **Build from MD** attaches a saved brief plus prioritized project source, preflights the request against the selected context window, and shows the exact local-model request before sending.
- Model replies remain proposals. Patch review validates paths and hunks, backs up existing files, and writes only after explicit apply. Malformed output is retained in the transcript and makes no project changes.
- Project enumeration now reports access failures. The empty explorer tells the operator to reselect a folder when its files cannot be read.

## Verification — November 1

- `swift test`: 284 core tests and 111 app tests passed; 16 opt-in tests skipped; zero failures.
- `git diff --check` passed.
- The isolated QA app opened a disposable project, listed both files, opened its brief, discovered local Qwen, and showed the exact frozen request.
- Local Qwen returned malformed patches twice. The first also changed existing behavior. Wampum rejected both responses; readback confirmed the disposable `app.py` was unchanged. Model output accuracy has not passed this check.
- App/core tests cover valid patch application, backup creation, changed-file tabs, malformed-patch rejection, context selection and overflow handling.

## Release blocker

Coin Droppa has not passed the acceptance workflow. No Coin Droppa files were changed during this QA run. Wampum's source can ship independently, but Coin Droppa is not ready: complete its cleanup through Wampum, inspect every proposed file, and run the project's relevant checks before calling that project ready.

## Recovery reference

The interrupted local merge recovery remains at `/private/tmp/wampum-interrupted-recovery-20261031/`. The prior known-good feature commit is `900abb9` on `tools-pentest-orchestration`.
