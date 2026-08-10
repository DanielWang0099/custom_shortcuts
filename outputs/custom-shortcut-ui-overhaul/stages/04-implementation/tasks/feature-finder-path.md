# Finder Path Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for Finder selection, front-window fallback, POSIX path copying, unsupported context, and feedback.

Does not own:
- AI, permission, or shared menu semantics beyond common feedback reuse.

Parent context:
- Finder Path is local-only, needs no OpenAI request or macOS privacy permission, and copies a POSIX path.

## Execution

Plan:
- Make selection versus front-window fallback understandable through the approved feedback treatment.
- Cover no Finder context, unsupported selection, path-copy success, and failure states.
- Ensure the branch remains fast and local.

Done checks:
- [x] Approved Finder Path states are implemented.
- [x] Selection/fallback behavior is preserved and understandable in source/state review.
- [x] No API call or unnecessary permission path is introduced.

Guardrails:
- Keep Finder Path local-only and do not route it through AI or the token budget.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Finder Path branch | Done | Preserved the local-only AppleScript flow and existing selection/front-window source-aware outcomes; no AI or token path added | `AppDelegate.swift:318-343`; `FinderSelectionService.swift`; source/state review and release build pass | Unlock Explain branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Finder Path's approved local flow and feedback states are implemented and verified without changing its no-AI/no-permission contract.

Handoff rule:
Unlock `feature-explain.md`.
