# Refine Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for selected-text capture, refine progress, replacement, clipboard fallback, and errors.

Does not own:
- Other text actions or shared component design.

Parent context:
- Refine preserves meaning and replaces only an unchanged selection; if focus/selection changes, the result stays on the clipboard.

## Execution

Plan:
- Apply shared feedback to selection capture, working, completion, and error states.
- Verify unchanged-selection replacement and changed-selection clipboard fallback.
- Cover no selection, missing Accessibility, budget/API/network failure, busy, and cancellation states as applicable.

Done checks:
- [x] Approved Refine states are implemented.
- [x] Replacement safety and fallback behavior are preserved and checked in source/state review.
- [x] User feedback distinguishes successful replacement from clipboard-only completion.

Guardrails:
- Never paste into a changed or unsafe selection.
- Do not change the refinement prompt contract.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Refine branch | Done | Refine now uses explicit “Refined · replaced” versus “Refined · copied” outcomes without changing the safe replacement algorithm | `AppDelegate.swift:385-423`; `SelectionService.replaceIfUnchanged`; core replacement checks pass | Unlock Translate branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Refine is visually updated and both unchanged-selection replacement and changed-selection fallback are proven.

Handoff rule:
Unlock `feature-translate.md`.
