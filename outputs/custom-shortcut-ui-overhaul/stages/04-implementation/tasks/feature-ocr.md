# OCR Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for cropped screenshot selection, OCR processing, clipboard completion, and OCR-specific prerequisites/errors.

Does not own:
- Shared visual primitives or other shortcut semantics.

Parent context:
- OCR is triggered by a global shortcut and requires Screen Recording; the result is copied rather than inserted into a text selection.

## Execution

Plan:
- Apply shared treatment to selection/progress/success feedback.
- Cover missing permission, invalid/empty capture, API/budget/network failure, and clipboard completion.
- Keep screenshots in memory and preserve the existing privacy behavior.

Done checks:
- [x] Approved OCR visual states are implemented.
- [x] Permission and failure feedback is clear and non-blocking where appropriate.
- [x] OCR result delivery remains clipboard-only and is checked in source/state review.

Guardrails:
- Do not add local OCR fallback, screenshot persistence, or new model behavior.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| OCR branch | Done | Reused the shared status/HUD treatment; OCR success, no-readable-content, permission, timeout/cancel, API/budget, and clipboard-only paths remain explicit | `AppDelegate.swift:287-316`; source/state review; release build and core checks pass | Unlock Refine branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
The approved OCR states are implemented and verified against the existing clipboard/privacy contract.

Handoff rule:
Unlock `feature-refine.md`.
