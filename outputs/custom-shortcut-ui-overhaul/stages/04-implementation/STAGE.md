# Stage 4 - Implementation and Verification

Node type: Stage
Status: Complete
Parent: Project root
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Approved shared visual foundation, shared operational surfaces, six feature branches, and final verification.

Does not own:
- Unapproved product expansion, provider/model changes, privacy-policy changes, or unrelated refactors.

Parent context:
- Stage 4 proceeds after Stage 2 approval and Stage 3 research/map completion. It has no additional hard approval gate.

## Execution

Plan:
- Implement shared visual treatment and common operational states.
- Implement each shortcut branch independently in the queue.
- Preserve existing contracts while changing presentation and necessary supporting behavior.
- Run build/checks and complete manual state and visual verification.

Done checks:
- [x] Shared foundation and all six feature children have evidence.
- [x] Existing core checks and release build pass, or failures are recorded.
- [x] All six actions and important failure states have explicit source/state evidence.
- [x] Parent handoff is complete; unavailable accessory-menu pixel inspection is explicitly deferred to the owner.

Guardrails:
- Only implement the approved Stage 2 scope plus necessary supporting code.
- Keep exactly one implementation tracking row active or modified at a time.
- Preserve selection safety, clipboard fallback, hidden Explain context, permissions, budget guard, and privacy/logging behavior.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Shared visual foundation | Done | `tasks/shared-foundation.md` | Shared AppKit style/material helper, readiness, prompt, HUD, onboarding, and outcome treatment implemented and buildable | Implement OCR branch |
| OCR | Done | `tasks/feature-ocr.md` | OCR states and clipboard/privacy contract are covered in source/state review | Implement Refine branch |
| Refine | Done | `tasks/feature-refine.md` | Safe replacement and clipboard fallback now have distinct outcome copy | Implement Translate branch |
| Translate | Done | `tasks/feature-translate.md` | Contextual entry and clipboard-only outcome are covered | Implement Format branch |
| Format | Done | `tasks/feature-format.md` | Contextual entry and replacement/fallback outcomes are covered | Implement Finder Path branch |
| Finder Path | Done | `tasks/feature-finder-path.md` | Local-only source-aware path feedback remains intact | Implement Explain branch |
| Explain/chat | Done | `tasks/feature-explain.md` | Explain hierarchy, loading, error, dismissal, and hidden-context treatment are covered | Run integration verification |
| Integration verification | Done | `tasks/integration-verification.md` | Nine core checks, release build, signed install, current shortcut coverage, and the accessory-menu inspection limitation are recorded | Close Stage 4 |

## Child Nodes

| Child file | Owns | Status | Handoff rule |
| --- | --- | --- | --- |
| `tasks/shared-foundation.md` | Shared visual tokens and common surfaces | Complete | Shared treatment implemented and buildable |
| `tasks/feature-ocr.md` | OCR UI/feedback branch | Complete | OCR state and privacy contract covered |
| `tasks/feature-refine.md` | Refine UI/feedback branch | Complete | Refine outcome and safety treatment covered |
| `tasks/feature-translate.md` | Translate UI/feedback branch | Complete | Translate entry and clipboard contract covered |
| `tasks/feature-format.md` | Format UI/feedback branch | Complete | Format entry and safety treatment covered |
| `tasks/feature-finder-path.md` | Finder Path UI/feedback branch | Complete | Finder local-only contract covered |
| `tasks/feature-explain.md` | Explain/chat UI/feedback branch | Complete | Explain hierarchy and privacy contract covered |
| `tasks/integration-verification.md` | Build, checks, manual matrix, visual pass | Complete | Current feature evidence recorded; owner-only pixel inspection is deferred |

## Completion And Handoff

Completion rule:
All eight children are complete or explicitly deferred with reasons, and the final verification node records build/check/manual/visual evidence.

Handoff rule:
Close the project only after the completion rule in `MASTER_PROGRESS.md` is satisfied and no approved branch is unproven.
