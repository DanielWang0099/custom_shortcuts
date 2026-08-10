# Feature-Flow Audit - Six Shortcut Actions

Node type: Task
Status: Complete
Parent: `stages/01-discovery/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The current end-to-end flow for OCR, Refine, Translate, Format, Finder Path, and Explain/chat.
- Input, processing, result delivery, feedback, prerequisite, busy/cancel, success, failure, and feature-specific safety behavior.

Does not own:
- Shared menu/onboarding critique, final visual direction, Apple research, or code changes.

Parent context:
- The app is a fast menu-bar utility. The audit must state what the user is trying to accomplish and where the current flow helps or obstructs that goal.

## Execution

Plan:
- Read README, domain contracts, controllers, and tests for each action.
- Trace the trigger-to-result flow and inspect available runtime behavior when possible.
- Record only meaningful state branches and the clearest user-facing friction.

Done checks:
- [x] All six rows contain current flow, user goal, meaningful states, and evidence.
- [x] Refine and Format replacement safety/clipboard fallback are explicitly checked.
- [x] Explain hidden-selection and chat behavior are explicitly checked.
- [x] Results are handed to the shared-surface and critique nodes.

Guardrails:
- Do not infer a UI state from an idealized flow when source behavior differs.
- Do not propose model, privacy, or shortcut changes in this node.

## Audit Findings

Source evidence below is based on the current AppKit controllers, core domain contracts, README, and passing core checks. Runtime visual inspection was not performed because launching the accessory app would trigger data-sharing and macOS permission flows; those visual claims remain for Stage 4 verification.

| Feature | Current flow and contract | Meaningful states | Current UI/UX critique |
| --- | --- | --- | --- |
| OCR | Global shortcut -> readiness/API/Screen Recording gates -> interactive `screencapture` crop -> image token reservation -> Responses API -> OCR text copied to clipboard. Evidence: `Sources/AIShortcuts/AppDelegate.swift:222-316`, `Sources/AIShortcuts/ScreenshotService.swift:25-96`, `Sources/AIShortcutsCore/Domain.swift:103-115`. | Not enabled, missing key, missing Screen Recording, crop success, Escape/empty capture, API/budget/network failure, no readable text, copied success, cancellation/timeout. | The user goal is fast text extraction, but the crop stage has no app-owned context or progress treatment. Escape returns silently, and success is only a short HUD. The result destination is clear only after completion; the shortcut is not discoverable from the menu. |
| Refine | Global shortcut -> Accessibility/readiness gates -> selected text via Accessibility or synthetic Copy -> full-model request -> replace only if the original process and selection are unchanged; otherwise leave result on clipboard. Evidence: `Sources/AIShortcuts/AppDelegate.swift:237-270,351-422`, `Sources/AIShortcuts/SelectionService.swift:13-88`, `Sources/AIShortcutsCore/Domain.swift:116-130,219-241`. | No selection, permission/key/budget failure, capture, working, API failure, unchanged replacement, changed selection clipboard fallback, cancellation/timeout. | The safety contract is excellent, but the UI does not explain whether the result replaced text or was copied unless the user catches the transient message. A failed request can leave the captured text on the clipboard because capture does not preserve it. That is a behavior/feedback risk to decide in Stage 2, not to change during audit. |
| Translate | Global shortcut -> capture selected text -> blank parameter panel -> app reactivation -> full-model request -> translated result copied only. Evidence: `Sources/AIShortcuts/AppDelegate.swift:272-275,360-383,385-422`, `Sources/AIShortcuts/PromptPanelController.swift:11-105`. | No selection, missing Accessibility/key/budget, parameter panel, Enter submit, empty/cancel/focus loss, API failure, clipboard success, cancellation/timeout. | The user must know the field is for a target-language instruction, but the panel has no title or placeholder and is visually identical to Format. This is the clearest discoverability failure: the flow is fast once understood but context-free at the exact moment a decision is required. |
| Format | Global shortcut -> capture selected text -> same blank parameter panel -> app reactivation -> full-model request -> replace unchanged selection or copy when changed. Evidence: `Sources/AIShortcuts/AppDelegate.swift:272-275,360-422`, `Sources/AIShortcuts/PromptPanelController.swift:11-105`. | No selection, missing Accessibility/key/budget, instruction panel, Enter submit, empty/cancel/focus loss, API failure, unchanged replacement, changed selection clipboard fallback, cancellation/timeout. | Format shares Translate's context-free panel despite needing a different instruction. It also shares the replacement-safety message, so the user gets no persistent confirmation of what happened. A small feature-specific prompt label and explicit result wording would improve trust without adding a step. |
| Finder Path | Global shortcut -> local AppleScript reads Finder selection or front window -> canonical POSIX paths copied -> HUD feedback. Evidence: `Sources/AIShortcuts/AppDelegate.swift:280-283,318-349`, `Sources/AIShortcuts/FinderSelectionService.swift:24-101`. | Finder not running, selected items, front-window fallback, empty context, Automation denial, script failure, one/multiple path success, cancellation/timeout. | This is the fastest and simplest feature, but the fallback is implicit until the final message says “Folder path copied.” The user cannot discover it from the menu, and the Automation recovery message is buried in a transient HUD. The feature should stay local-only and lightweight. |
| Explain/chat | Global shortcut -> selected text captured while preserving clipboard -> compact borderless panel; selected text stays hidden and is represented only by the placeholder -> prompt submit -> full-model request with bounded transient memory -> answer rendered in the panel. Evidence: `Sources/AIShortcuts/AppDelegate.swift:222-235,424-540`, `Sources/AIShortcuts/ExplanationPanelController.swift:1-362`, `Sources/AIShortcutsCore/ExplanationMemory.swift:1-111`. | General chat/no selection, hidden selection, empty request with selection, loading, in-flight reopen, answer, refusal/network/budget error with retry, focus-loss dismissal, background completion, one-hour reset. | The privacy behavior is deliberate and strong, but the panel is visually opaque: no title, close affordance, attached-context indicator beyond placeholder text, or distinct user/assistant treatment. Focus-loss dismissal is efficient for a shortcut utility but can feel like accidental data loss unless the background-completion state is made obvious. |

## Cross-Feature Evidence

- All six actions are declared in `AIShortcutAction` and mapped to global defaults in `Sources/AIShortcutsCore/Domain.swift:3-55`; the existing test suite checks the mappings and permission and API contracts.
- Every action is gated through `AppDelegate.handle`; the shared order is busy -> data sharing -> API key where required -> Accessibility -> Screen Recording -> action-specific capture.
- Shared operation state is represented by `isBusy`, the status-menu icon, a 120-second timeout, cancellation, and HUD feedback in `Sources/AIShortcuts/AppDelegate.swift:620-687` and `Sources/AIShortcuts/HUDController.swift:1-92`.
- Existing automated evidence is strong for core behavior: `swift run AIShortcutsCoreChecks` passed all seven suites, including prompt contracts, replacement policy, explanation memory, budget, request construction, success, and API errors. `swift build -c release` also passed.
- Automated tests do not prove menu hierarchy, panel context, focus behavior, typography, accessibility labels, appearance variants, or transient feedback timing. Those remain manual/UI verification requirements.

## Stage 1 Design Implications

1. Improve discoverability at the status menu without turning it into a settings dashboard: the six actions and their shortcuts need a clear, quiet home.
2. Give Translate and Format a shared parameter surface with feature-specific title/placeholder/instruction context; preserve the one-field, Enter-to-submit flow.
3. Make result delivery explicit and consistent: distinguish copied, replaced, fallback-copied, cancelled, and no-op outcomes in a way that survives a brief glance.
4. Give OCR crop and Finder fallback/error states a concise explanation while preserving their speed and local/clipboard behavior.
5. Make Explain's hidden context, loading, retry, and dismissal states legible without rendering selected text or introducing persistence.
6. Use a restrained shared visual system for menu, panel, HUD, and state messaging; avoid feature-specific ornament.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| OCR | Done | Source-backed flow recorded above | `AppDelegate.swift:287-316`; `ScreenshotService.swift:25-96` | Continue to Refine |
| Refine | Done | Source-backed flow recorded above | `AppDelegate.swift:351-422`; `SelectionService.swift:13-88`; core checks passed | Continue to Translate |
| Translate | Done | Source-backed flow recorded above | `AppDelegate.swift:360-422`; `PromptPanelController.swift:11-105` | Continue to Format |
| Format | Done | Source-backed flow recorded above | `AppDelegate.swift:360-422`; replacement policy checks passed | Continue to Finder Path |
| Finder Path | Done | Source-backed local flow recorded above | `FinderSelectionService.swift:24-101`; `AppDelegate.swift:318-349` | Continue to Explain |
| Explain/chat | Done | Source-backed flow recorded above | `AppDelegate.swift:424-540`; `ExplanationPanelController.swift:1-362`; memory checks passed | Handoff to shared-surface audit |

## Child Nodes

No child nodes. Each row is an independently verifiable feature branch within this task.

## Completion And Handoff

Completion rule:
Every one of the six tracking rows is Done, Deferred with a reason, or Waived, with a source/runtime evidence note and a clear user goal.

Handoff rule:
Pass the six-feature flow map to `../shared-surface-audit.md` for shared context and then `../experience-critique.md` for prioritization.
