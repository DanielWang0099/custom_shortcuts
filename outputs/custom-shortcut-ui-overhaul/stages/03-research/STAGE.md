# Stage 3 - Official Apple UI Research and Pattern Mapping

Node type: Stage
Status: Complete
Parent: Project root
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Official Apple research relevant to the approved visual direction and its mapping to implementation branches.

Does not own:
- New design scope, user approval, or code changes.

Parent context:
- Stage 2 approval is the only hard gate. Once approved, research should proceed pragmatically and should not create a new approval process.

## Execution

Plan:
- Gather official Apple documentation and examples for selected patterns.
- Check availability against the app's macOS 13 target and AppKit architecture.
- Map patterns and code templates to approved branches, choosing the simplest compatible option.

Done checks:
- [x] Official sources, access dates, APIs, and compatibility notes are recorded.
- [x] Each adopted pattern maps to an approved branch.
- [x] Unsupported or scope-expanding ideas are deferred with reasons.

Guardrails:
- Use official Apple sources for current platform claims.
- Do not let research introduce new product scope or a new hard gate.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Official source research | Done | `tasks/liquid-glass-research.md` | Official sources, access dates, AppKit patterns, and macOS 13 compatibility decision recorded | Map selected patterns |
| Pattern-to-branch map | Done | `tasks/pattern-mapping.md` | Every approved branch has a compatible native pattern, code-template note, or explicit deferral | Unlock Stage 4 shared foundation |

## Child Nodes

| Child file | Owns | Status | Handoff rule |
| --- | --- | --- | --- |
| `tasks/liquid-glass-research.md` | Official guidance and compatibility | Complete | Source record and compatibility decision complete |
| `tasks/pattern-mapping.md` | Selection and mapping rationale | Complete | Branch mapping and handoff complete |

## Completion And Handoff

Completion rule:
Both research children have source-backed outputs or explicit limitations, and no adopted pattern lacks compatibility or branch mapping.

Handoff rule:
Unlock Stage 4 after the research/map evidence is complete. This is a work-order handoff, not a new user approval gate.
