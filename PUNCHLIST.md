# Wampum — November 1, 2026

## Target

Use Coin Droppa as the real acceptance task: Wampum must supply the selected project sources to Qwen, produce a reviewable multi-file change, apply it only after review, and leave the verified files on disk. Coin Droppa is not a RAILGUN project and has no demo release target.

## Verified

- [x] The full default suite passed before the patch workflow change: 280 core and 107 app tests, with 16 opt-in skips and no failures.
- [x] After the patch workflow change, the full suite passed: 284 core and 108 app tests, with 16 opt-in skips and no failures. `git diff --check` passed.
- [x] November 1 current suite: 284 core and 111 app tests passed, 16 opt-in skips, zero failures. `git diff --check` passed.
- [x] Coin Droppa's current site build publishes nine allowlisted files. Its engine smoke script passes ten checks for deterministic signatures, wallet reopening, engine startup, and balance API presence.
- [x] Live Qwen source review returned eight quoted spans; one matched the attached sources and seven failed exact-source review. The output treated the game preview as deployable and proposed retaining RAILGUN, contrary to the owner's direction.
- [x] `mixer.html` is 70,519 bytes. Wampum's source attachment limit is 32,000 bytes, so it could not ground a response in the main Coin Droppa file.
- [x] Added reviewed unified-diff support for multi-file edits, new files, and requested deletions. It checks paths and patch applicability, rejects renames, binaries, symlinks, `.git`, and `.env` files, backs up changed originals locally, then opens surviving changed files in editor tabs.
- [x] Focused patch tests passed: four core tests and one Workbench apply-to-disk test.
- [x] A real local QA run confirmed the request preview and exposed malformed Qwen diffs. Patch review rejected both responses, including a behavior-changing diff; the disposable project remained unchanged.
- [x] Built an isolated QA app with a private state directory and opened the Coin Droppa project in it. Normal Wampum data stays separate.

## Remaining

- [x] Run the full Swift suite and `git diff --check` with reviewed patch support.
- [x] Build and launch a separate QA app; open Coin Droppa without touching the owner's active Wampum session.
- [ ] Through Wampum, complete the authorized Coin Droppa cleanup task from its active brief. Inspect every proposed file and keep the project's requested direction consistent; do not treat malformed or unreviewed model output as a change.
- [ ] Verify the changed Coin Droppa files on disk, inspect the complete diff, and run the relevant build and tests.
- [x] Reconcile README and status docs with the verified result, including the live Qwen failure and the fail-closed patch-review result.
- [ ] Complete Coin Droppa through Wampum, verify the changed files and project checks, then publish that project result. Coin Droppa remains unfinished.

Qwen's live review was an accuracy failure. The Workbench now has a multi-file patch path that can address Coin Droppa's file-size and single-file-proposal limits; the Coin Droppa acceptance task has not passed yet.

## Usability workflow — verified November 1

- Normal requests attach only the active editor file; all-open-tab and source-review switches are collapsed under **Context options** and start off.
- **Build from MD** uses a saved Markdown brief, gathers local project sources while excluding generated/vendor folders and lockfiles, prioritizes paths named in the brief, previews the exact request, and routes the returned diff through **Review Patch** / **Apply Reviewed Patch**.
- The build context is limited to 84,000 source bytes and selects a 32K model context; omitted paths are listed in the exact request. Context preflight and patch apply/backup are covered by tests.
- A fresh QA app opened the disposable project, listed its files, opened the brief, discovered local Qwen, and displayed the exact frozen request. The local model returned malformed diffs on two attempts; Review Patch rejected both and the fixture's `app.py` remained byte-for-byte unchanged.
- The first QA instance had a stored project path but no readable file list. File enumeration now reports failures instead of silently returning an empty list, and the explorer explains how to reselect an inaccessible folder.
- Coin Droppa remains the full acceptance task. Its release changes have not been applied or verified; do not mark that project ready based on Wampum transport or patch-parser tests.
