# Format Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for formatting instruction entry, selected-text capture, replacement safety, clipboard fallback, and errors.

Does not own:
- Translate semantics or shared visual foundation.

Parent context:
- Format uses a typed instruction and replaces only an unchanged selection; changed selection means clipboard fallback.

## Execution

Plan:
- Apply the approved input and feedback treatment.
- Verify unchanged-selection replacement and changed-selection clipboard fallback.
- Cover empty input/selection, Accessibility, busy/cancel, API/budget/network failure, and success.

Done checks:
- [x] Approved Format states are implemented.
- [x] Replacement safety/fallback behavior is preserved and checked in source/state review.
- [x] Input and result feedback are consistent with Refine where appropriate.

Guardrails:
- Do not make formatting destructive when focus or selection changed.
- Do not change the formatting prompt contract.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Format branch | Done | Added visible Format context and instruction example; reuses explicit replacement versus clipboard-fallback outcomes | `PromptPanelController.swift`; `AppDelegate.swift:360-423`; replacement policy and core checks pass | Unlock Finder Path branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Format's approved entry, replacement safety, fallback, and failure states are implemented and checked.

Handoff rule:
Unlock `feature-finder-path.md`.
