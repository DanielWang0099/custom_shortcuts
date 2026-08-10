# Explain/Chat Feature Branch

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved UI/UX treatment for Explain/chat launch, hidden selected-text attachment, composer, transcript, loading, errors, dismissal, background completion, and inactivity reset.

Does not own:
- General product chat expansion, persistence, model/provider changes, or shared HUD behavior beyond reuse.

Parent context:
- Explain stays in one compact borderless panel, does not render hidden selected text in the composer/transcript, closes on focus loss, continues in-flight work, and keeps transient bounded memory.

## Execution

Plan:
- Apply the approved panel/composer/transcript hierarchy and focus behavior.
- Cover with/without selected text, empty prompt, loading, background completion, error/refusal, dismissal, and one-hour reset.
- Preserve bounded memory, hidden-selection privacy, and current full-model/prompt contracts.

Done checks:
- [x] Approved Explain states are implemented.
- [x] Hidden selection is never rendered in the composer/transcript.
- [x] Loading, background completion, dismissal, error, and reset behavior are checked in source/state review.
- [x] Panel remains compact and quick to reopen.

Guardrails:
- Do not add persistence, transcript export, extra chat features, fallback models, or logging.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Explain/chat branch | Done | Added Explain header/context state, readable user/answer labels, semantic composer styling, loading/error treatment, and hidden-selection continuity | `ExplanationPanelController.swift`; `AppDelegate.swift:424-550`; hidden selection remains out of rendered text and memory/reset contracts are unchanged | Unlock integration verification |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Explain's approved compact chat experience and hidden-selection/background/reset contracts are implemented and checked.

Handoff rule:
Unlock `integration-verification.md` after this branch is complete.
