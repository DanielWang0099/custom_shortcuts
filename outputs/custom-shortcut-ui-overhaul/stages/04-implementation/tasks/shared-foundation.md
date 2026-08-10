# Shared Visual Foundation and Operational Surfaces

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Reusable visual tokens/components and shared menu, onboarding, permission, key/budget, HUD, busy, cancel, restart, and feedback treatment approved in Stage 2.

Does not own:
- Feature-specific result semantics or shortcut-specific behavior changes.

Parent context:
- Shared treatment must make the six features feel like one fast utility and must not create a larger settings product.

## Execution

Plan:
- Implement approved spacing, typography, symbols, materials, colors, focus, and feedback primitives.
- Apply them to menu/status, onboarding/permissions, readiness/budget, HUD, busy/cancel, restart, and error/success surfaces.
- Check light/dark appearance and accessibility where the approved plan requires it.

Done checks:
- [x] Shared tokens/components are used consistently by affected surfaces.
- [x] Operational states remain understandable without adding unnecessary steps.
- [x] No feature branch is forced to duplicate the shared treatment.

Guardrails:
- Keep idle surfaces quiet and fast to scan.
- Do not change permission, key, budget, or privacy policy semantics.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Shared visual and operational treatment | Done | Added shared AppKit style/material helpers and applied them to menu, onboarding, prompt, HUD, Explain, readiness, and outcome copy | ShortcutUIStyle.swift; release build and core checks pass; safety/permission contracts unchanged | Unlock OCR branch |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Approved shared primitives and surfaces are implemented, buildable, and visually coherent enough for feature branches to reuse.

Handoff rule:
Unlock `feature-ocr.md` and carry the shared component names and state rules forward.
