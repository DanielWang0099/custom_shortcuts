# Stage 2 - Approved Visual/UX Direction and Implementation Specification

Node type: Stage
Status: Approved
Parent: Project root
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The compact visual direction, prioritized redesign, and implementation-ready specification derived from Stage 1.

Does not own:
- Code changes or Apple pattern research before the single approval gate is resolved.

Parent context:
- The user wants a better-looking app without a complicated long-horizon plan. The Stage 2 output must be concrete enough to approve quickly.

## Execution

Plan:
- Define visual principles and priorities.
- Define per-feature target experiences and state treatment.
- Translate must-have changes into branch-level implementation contracts.
- Ask for one explicit user approval after the specification is complete.

Done checks:
- [x] Visual direction and prioritization are recorded.
- [x] All six features and shared surfaces have target states.
- [x] Implementation specification names components/branches and verification.
- [x] The single approval row is resolved before Stage 3 or Stage 4 starts.

Guardrails:
- No coding before explicit approval in `MASTER_PROGRESS.md`.
- Do not add a new hard gate after this one.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Visual direction | Done | `tasks/visual-direction.md` | Visual direction and priority map complete | Implementation specification |
| Implementation specification and approval | Approved | `tasks/implementation-spec.md` | User approval recorded; Stage 2 scope is unlocked | Handoff to Stage 3 research |

## Child Nodes

| Child file | Owns | Status | Handoff rule |
| --- | --- | --- | --- |
| `tasks/visual-direction.md` | Visual language and priority decisions | Ready | Close before implementation spec |
| `tasks/implementation-spec.md` | Per-branch code scope and the single gate | Locked | Unlock Stage 3/4 after explicit approval |

## Completion And Handoff

Completion rule:
Both children are complete or deferred with reasons, and the Stage 2 approval gate is explicitly Approved or Waived.

Handoff rule:
After approval, Stage 3 research and Stage 4 implementation proceed without additional hard approval gates. If the gate is not approved, keep downstream nodes locked.
