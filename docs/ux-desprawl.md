# Wampum — UX de-sprawl proposal

_November 4, 2026. Written from a live playtest of `build/Wampum.app` against the `bug_bounty` project._

## Premise

The gate (request review, local-only, scope gating) is the product's strength and is untouched here. The weakness is surface area: the UI reads as a research instrument rather than a focused tool. Even inside a single surface (Editor) there are three dense columns plus a five-item top nav and a lot of ambient copy. This proposal trims presentation only — no security feature or model-request path is removed, and everything stays reachable.

## Observed during playtest

- Clean boot to an empty workspace works (the Close Project fix).
- Opening `bug_bounty` and running the local model through the review gate works; the gate preview is clear and honest.
- **Bug:** after switching projects (coin_droppa → bug_bounty), the Check Runner pane still showed the previous project's command and output. Project state reset covers the session but not the model-level `output`/`command`.

## Changes

### 1. Collapse the document-export apparatus out of the chat loop
The right-hand chat panel carried two inline menus (`Export Markdown`, `Document`) plus an explainer caption, competing with the core ask → review → apply loop. These duplicate commands already present in the **File** menu, and per-message replies still have their own **Save Reply…** button. Remove the inline menus and caption; keep the File-menu commands and the per-message button.

### 2. Top bar: five surfaces → three, plus an overflow
`Editor / Browser / Tools` are the daily loop and stay as the segmented control. `Controller` and `Integrity` are meta/system surfaces; move them into a **System** overflow menu. Routing is unchanged — the menu sets the same `surface` state — so both remain one click away and every panel and test is intact.

### 3. Trim ambient chrome
- Remove the `M4 / 16 GB` hardware vanity readout from the top bar.
- Shorten the context-profile caption from a memory lecture to a one-line constraint.
- Reduce the footer tag to the one security-relevant signal (`LOCAL INFERENCE`), dropping the vanity trailer.

### 4. Fix stale Check Runner state on project switch
Reset the model-level `command` and `output` in `chooseProject()` and `closeProject()`, matching the existing scenario/case-switch behavior, so the runner pane reflects the newly opened project.

## Out of scope / deliberately kept

- The gate, masking, network guard, scope, and checkpoints are unchanged.
- No panel or capability is deleted; Controller and Integrity move, they do not disappear.
- Model behavior and the local-inference path are untouched.

## Verification

Full Swift suite (`swift test`) after the changes; no test asserts the removed chrome strings, and `CloseProjectTests` is extended to cover the runner-state reset.
