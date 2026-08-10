# Stage 1 - Current-State Discovery and Feature-Flow Audit

Node type: Stage
Status: Complete
Parent: Project root
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The evidence-backed baseline for all six shortcut actions and shared app surfaces.
- The handoff from observed behavior to a concise experience critique.

Does not own:
- UI code changes, final redesign decisions, Apple research, or implementation.

Parent context:
- Simplicity is the governing preference; challenge the current experience without expanding the product.
- The audit must cover every known action and meaningful state, not only the happy path.

## Execution

Plan:
- Complete the feature-flow inventory first.
- Complete the shared-surface audit next.
- Turn both audits into a prioritized critique and change list.

Done checks:
- [x] All three child audits have evidence or an explicit deferred limitation.
- [x] Six actions and shared surfaces are accounted for.
- [x] The critique identifies user goal, friction, reason, priority, and proposed change.
- [x] Tracking and handoff are mirrored in `MASTER_PROGRESS.md`.

Guardrails:
- Do not implement or silently change scope during discovery.
- Record runtime limitations instead of claiming visual validation that did not occur.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Feature-flow audit | Done | `tasks/feature-flow-audit.md` | Six feature rows complete; source/build evidence recorded | Shared-surface audit |
| Shared-surface audit | Done | `tasks/shared-surface-audit.md` | Five shared rows complete; source evidence recorded | Experience critique |
| Experience critique | Done | `tasks/experience-critique.md` | Prioritized change list and Stage 2 decision set complete | Handoff to Stage 2 |

## Child Nodes

| Child file | Owns | Status | Handoff rule |
| --- | --- | --- | --- |
| `tasks/feature-flow-audit.md` | Six shortcut flows and feature-specific states | Active | Close with six evidence-backed rows |
| `tasks/shared-surface-audit.md` | Menu, onboarding, permissions, key/budget, HUD, restart/cancel | Ready | Close with shared-surface evidence |
| `tasks/experience-critique.md` | Prioritized critique and candidate changes | Locked | Close with Stage 2-ready change list |

## Completion And Handoff

Completion rule:
All three child nodes are complete or explicitly deferred with reasons, and the Stage 1 critique names the full covered scope and limitations.

Handoff rule:
Unlock Stage 2 visual direction after the parent evidence is recorded. No code or Apple pattern adoption begins here.
