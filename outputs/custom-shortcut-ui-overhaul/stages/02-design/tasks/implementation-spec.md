# Implementation Specification and Stage 2 Approval

Node type: Task
Status: Approved
Parent: `stages/02-design/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The approval-ready implementation plan for shared UI, onboarding/operations, OCR, Refine, Translate, Format, Finder Path, Explain/chat, and final verification.
- The single hard user approval gate after Stage 2.

Does not own:
- Actual code edits or the Stage 3 Apple source investigation.

Parent context:
- Every selected change must be implementable, state-aware, and simple enough to preserve the quick flow.

## Execution

Plan:
- For each prioritized change, identify affected controller/view/component, callers/contracts, behavior states, and proof.
- Split the six features into independently verifiable branches and carry forward their safety contracts.
- Identify shared work that should be implemented once.
- Record must-have, should-have, and deferred items.
- Present the complete specification to the user and record explicit approval or requested changes.

Done checks:
- [x] Shared foundation and all six feature branches are named.
- [x] Each branch includes prerequisite, busy/cancel, success, failure/unsupported, and safety states as applicable.
- [x] Every must-have has a verification method and scope boundary.
- [x] The user approval decision is recorded in `MASTER_PROGRESS.md`.

Guardrails:
- This is the only hard approval gate in the workflow.
- Silence is not approval. Until explicit approval, Stage 3 and Stage 4 remain locked.
- If the user requests material scope changes, revise the plan before proceeding.

## Approval-Ready Specification

### Approved-Scope Proposal

The recommended implementation is a focused shared-system pass plus targeted feature treatments. It changes visible hierarchy, context, and feedback; it does not add actions, persistence, a settings window, or model/provider behavior.

| Branch | Proposed implementation | Affected current surfaces | Proof required |
| --- | --- | --- | --- |
| Shared visual foundation | Add a small shared style/primitives layer for semantic colors, spacing, typography, symbols, panel/HUD radii, focus, and outcome copy. Reuse it across existing AppKit controllers. | `StatusMenuController.swift`, `PromptPanelController.swift`, `ExplanationPanelController.swift`, `HUDController.swift` | Build; light/dark or available appearance review; no duplicated per-feature styling where a shared primitive applies |
| Status menu and readiness | Add a compact discoverable shortcut reference for all six actions and their existing hotkeys. Reorder/group the menu around Ready/Working/Needs attention, then maintenance actions. Keep token/key diagnostics concise and preserve existing callbacks. | `StatusMenuController.swift`, `AppDelegate.swift`, `Domain.swift` | Menu source review and manual menu inspection; all six actions visible; no hotkey mapping changes |
| First-run and permission readiness | Restructure the existing disclosure into shorter readable sections and make permission/key/budget readiness easier to scan. Keep the same consent and System Settings destinations; do not add polling. | `AppDelegate.swift`, `StatusMenuController.swift` | Manual first-run/recovery review; consent/billing/privacy text remains present; permission routing unchanged |
| Shared outcome feedback | Define stable user-facing outcomes for copied, replaced, fallback-copied, cancelled, blocked, failed, and no-readable-content. Use concise HUD text/icon combinations and reserve long explanations for the menu/panel. | `HUDController.swift`, `AppDelegate.swift` | Each outcome has a manual trigger or source-level proof; no content logged; no notification spam |
| Contextual text input | Extend the shared one-field panel with action title, action-specific placeholder/helper copy, visible focus, and consistent Return/Escape behavior. Keep the current one-field geometry and focus-loss cancellation. | `PromptPanelController.swift`, `AppDelegate.swift` | Translate and Format manual review; empty/cancel/focus-loss states; no extra step or prompt persistence |
| Explain panel hierarchy | Add a compact header, non-sensitive “selection attached” state, clearer user/answer styling, loading/retry treatment, and keyboard dismissal clarity. Do not render hidden selection text or persist content. | `ExplanationPanelController.swift`, `AppDelegate.swift` | With/without selection, loading, retry, focus loss, background completion, one-hour reset; hidden text remains absent from UI |

### Per-Feature Contracts

| Feature | Approved UI/behavior treatment | States to prove | Explicitly preserve |
| --- | --- | --- | --- |
| OCR | Use the shared busy/outcome treatment around the system crop; keep success concise and distinguish no readable text from API failure. Treat Escape from the system crop as a quiet user cancellation; app-owned cancellation/timeout may show the shared cancelled state. | Permission missing, crop success, Escape, empty/missing image, no readable text, budget/API/network failure, clipboard success, timeout/cancel | Screenshot remains in memory; OCR remains clipboard-only and full-model |
| Refine | Use contextual action/result feedback so replacement success and clipboard fallback are unambiguous. Do not change the safe replacement algorithm in this scope. | No selection, Accessibility/key/budget failure, working, API failure, unchanged replacement, changed-selection fallback, cancel/timeout | Meaning-preserving prompt; changed selection is never overwritten |
| Translate | Show `Translate` context and a target-language placeholder such as “e.g. Japanese, formal”; keep result clearly clipboard-only. | No selection, input/cancel/focus loss, API/budget/network failure, clipboard success, cancel/timeout | Original selection is not replaced; free-form instruction semantics |
| Format | Show `Format` context and an instruction placeholder such as “e.g. concise email with bullets”; use the shared replacement/fallback outcome language. | No selection, input/cancel/focus loss, API/budget/network failure, unchanged replacement, changed-selection fallback, cancel/timeout | Existing format prompt and replacement safety |
| Finder Path | Use concise source-aware feedback: selected item path(s) versus front-window folder path; keep Automation recovery actionable. | Finder not running, selection, front-window fallback, empty context, Automation denial, script failure, one/multiple path success | Local-only AppleScript path flow; no API, budget, or Accessibility/Screen Recording requirement |
| Explain/chat | Keep the compact borderless panel but make attached-selection, user/answer, loading, retry, and dismissal states visually legible. Preserve background completion when focus is lost. | No selection/general chat, hidden selection, empty prompt with selection, loading, in-flight reopen, answer, refusal/network/budget retry, focus loss, background completion, one-hour reset | Hidden selection not rendered; transient bounded memory; no persistence/fallback model |

### Implementation Order

1. Shared style/primitives and outcome vocabulary.
2. Status menu, readiness, first-run disclosure, and common HUD behavior.
3. Contextual Translate/Format panel.
4. Explain panel hierarchy.
5. OCR, Refine, Translate, Format, Finder Path, and Explain feature verification passes.
6. Build, core checks, manual state matrix, and final visual/accessibility review.

### Approval Gate

Please approve or change the following implementation scope before any Stage 3 research or Stage 4 code work:

- Approve the six shared/feature branches in the proposal above.
- Approve the per-feature contracts and state coverage.
- Approve the recommended simple defaults: keep hotkey mappings, keep one-field Enter/Escape input, keep Explain hidden selection/transient memory, keep Finder local-only, and preserve Refine/Format replacement safety.
- Approve the priority order: shared foundation -> readiness/HUD -> Translate/Format input -> Explain hierarchy -> feature verification.

This is the single hard gate. Once explicitly approved, Stage 3 research and Stage 4 implementation continue without additional hard approval gates. Any ideas not listed above remain deferred.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Approval-ready implementation specification | Approved | User explicitly approved the specification | Shared foundation + 6 feature branches + verification; approval recorded in `MASTER_PROGRESS.md` | Handoff to Stage 3 research |

## Child Nodes

No child nodes. The branch rows belong in the specification and are materialized as Stage 4 nodes after approval.

## Completion And Handoff

Completion rule:
The specification is complete and the user has explicitly approved it, or every rejected/deferred branch has a recorded reason and the gate is explicitly Waived.

Handoff rule:
On approval, unlock Stage 3 and Stage 4. Stage 3 records research/mapping before Stage 4 implementation; no further hard approval is required.
