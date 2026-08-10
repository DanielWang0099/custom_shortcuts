# Translate Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for translate instruction entry, selected-text capture, clipboard-only result delivery, and translate-specific errors.

Does not own:
- Refine/Format replacement behavior or shared composer architecture beyond reuse.

Parent context:
- Translate uses an instruction typed into a blank field and copies the result without replacing the original selection.

## Execution

Plan:
- Improve instruction entry clarity and feedback while keeping the quick flow.
- Cover empty instruction/selection, Accessibility, busy/cancel, API/budget/network failure, and clipboard success.
- Reuse approved shared panel/HUD treatment.

Done checks:
- [x] Approved Translate states are implemented.
- [x] Instruction entry and selected-text context are understandable in source/state review.
- [x] Clipboard-only delivery and failure feedback are checked.

Guardrails:
- Do not add persistent prompt history or change the translate prompt semantics.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Translate branch | Done | Added visible Translate context and target-language example copy while preserving the one-field flow and clipboard-only result | `PromptPanelController.swift`; `AppDelegate.swift:360-410`; release build/core checks pass | Unlock Format branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Translate's approved entry, feedback, clipboard delivery, and failure states are implemented and checked.

Handoff rule:
Unlock `feature-format.md`.
