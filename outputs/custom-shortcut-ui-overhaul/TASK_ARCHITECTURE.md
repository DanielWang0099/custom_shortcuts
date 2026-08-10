# Custom Shortcut UI Overhaul - Task Architecture

This hierarchy is derived from `TASK_MODEL.md`. It is intentionally shallow: stage nodes own meaningful child passes, and Stage 4 has one leaf per independently verifiable original branch plus a final verification node that reconciles later delivered additions. The hierarchy is closed.

## Hierarchy Rules

- Stage nodes represent the four approved phases.
- Child task nodes own work that can be partially completed, needs distinct evidence, or has a distinct behavior contract.
- The historical queue was sequential for focus; no execution node is active now.
- A parent closes only after every required child is `Complete`, `Approved`, `Deferred` with a reason, or `Waived`.
- No child exists solely for a mechanical file edit.

## Recursive Granularity Rules

- Stage 1 separates feature flows, shared operational surfaces, and critique so coverage cannot collapse into a generic review.
- Stage 2 separates visual direction from implementation specification because the specification owns the single hard approval gate.
- Stage 3 separates official-source collection from pattern-to-branch decisions.
- Stage 4 separates shared foundation, each shortcut, and final integration because each branch can pass or fail independently.
- No deeper subtask level is needed unless execution reveals a meaningful branch that cannot be tracked in the current leaf.

## Lazy Points Scan

| Lazy point | Where it can fake done | Split / checklist type | Required evidence | Owning node |
| --- | --- | --- | --- | --- |
| Coverage shortcut | A broad review samples only the menu or one feature | Static checklist | Six original feature rows, four delivered local/AI additions, Shortcut Guide, and all shared-surface rows accounted for | `stages/01-discovery/tasks/feature-flow-audit.md`, `shared-surface-audit.md`, `stages/04-implementation/tasks/integration-verification.md` |
| Happy-path shortcut | A feature looks complete after one successful request | Behavior branch checklist | Applicable prerequisite, busy/cancel, success, failure/unsupported state for every feature | Stage 1 feature audits and Stage 4 feature nodes |
| Concept-only shortcut | A visual proposal has no implementable contract | Behavior branch checklist | Each approved change names component, state, affected caller/contract, and proof | `stages/02-design/tasks/implementation-spec.md` |
| Unofficial-pattern shortcut | Liquid Glass styling follows unsupported or vague examples | Static source checklist | Official URL, access date, API/platform note, and selected use | `stages/03-research/tasks/liquid-glass-research.md` |
| Build-only shortcut | Compilation is treated as product verification | Behavior branch checklist | Existing checks plus source/state or manual review of all registered shortcuts and important states | `stages/04-implementation/tasks/integration-verification.md` |

## Work-Order Gates

| Gate | Prior node | Next node | Why order matters | Unlock note | Status |
| --- | --- | --- | --- | --- | --- |
| Discovery pass 1 | `stages/01-discovery/tasks/feature-flow-audit.md` | `stages/01-discovery/tasks/shared-surface-audit.md` | Shared UI critique needs the feature inventory as context | Feature rows and evidence recorded | Complete |
| Discovery pass 2 | `stages/01-discovery/tasks/shared-surface-audit.md` | `stages/01-discovery/tasks/experience-critique.md` | The critique should use both feature and shared-surface facts | Both audits complete | Complete |
| Design handoff | `stages/01-discovery/STAGE.md` | `stages/02-design/STAGE.md` | Design should be based on the completed baseline | Stage 1 children closed | Complete |
| Design specification | `stages/02-design/tasks/visual-direction.md` | `stages/02-design/tasks/implementation-spec.md` | Implementation detail follows a settled visual direction | Visual direction recorded | Complete |
| Single approval gate | `stages/02-design/tasks/implementation-spec.md` | `stages/03-research/STAGE.md` and `stages/04-implementation/STAGE.md` | Research and code must use one approved scope | User approval recorded in `MASTER_PROGRESS.md` | Approved |
| Research handoff | `stages/03-research/STAGE.md` | `stages/04-implementation/STAGE.md` | Implementation uses the selected compatible patterns | Research/map complete; no new hard gate | Complete |
| Implementation sequence | `stages/04-implementation/tasks/shared-foundation.md` | Feature nodes in listed order | Shared treatment should exist before feature-specific polish | Shared foundation and feature branches complete | Complete |
| Verification handoff | `stages/04-implementation/tasks/feature-explain.md` | `stages/04-implementation/tasks/integration-verification.md` | Final checks need all feature branches present | Original branches and follow-up additions reconciled | Complete |

## Node Naming

```text
stages/01-discovery/STAGE.md
stages/01-discovery/tasks/feature-flow-audit.md
stages/02-design/tasks/implementation-spec.md
stages/03-research/tasks/pattern-mapping.md
stages/04-implementation/tasks/feature-explain.md
```

## Hierarchy Map

```text
Custom Shortcut UI Overhaul
  stages/01-discovery/STAGE.md
    tasks/feature-flow-audit.md
    tasks/shared-surface-audit.md
    tasks/experience-critique.md
  stages/02-design/STAGE.md
    tasks/visual-direction.md
    tasks/implementation-spec.md
  stages/03-research/STAGE.md
    tasks/liquid-glass-research.md
    tasks/pattern-mapping.md
  stages/04-implementation/STAGE.md
    tasks/shared-foundation.md
    tasks/feature-ocr.md
    tasks/feature-refine.md
    tasks/feature-translate.md
    tasks/feature-format.md
    tasks/feature-finder-path.md
    tasks/feature-explain.md
    tasks/integration-verification.md
```

## Task-To-Node Summary

| Request / output / constraint | Node(s) responsible | What the node owns | Small evidence note | Status |
| --- | --- | --- | --- | --- |
| Complete original feature-flow inventory | Stage 1 feature-flow audit | Six independent shortcut flows and state branches | Six completed rows | Covered |
| Audit shared app surfaces | Stage 1 shared-surface audit | Menu, onboarding, permissions, key/budget, HUD, restart/cancel | Shared-surface checklist | Covered |
| Challenge current experience | Stage 1 experience critique | User goals, friction, priorities, reasons, deferred items | Critique/change list | Covered |
| Describe approved redesign | Stage 2 visual direction and implementation spec | Visual system, target states, branch contracts | Approval-ready artifact | Covered |
| Research Apple patterns | Stage 3 research nodes | Official sources and compatibility | URLs/access dates | Covered |
| Implement original feature branches and delivered follow-ups | Stage 4 feature nodes and integration verification | OCR, Refine, Translate, Format, Finder Path, Explain/chat, Calculate, Input Lock, Sequential Clipboard, Insert, and Shortcut Guide | Build/source-state evidence | Covered |
| Verify simplicity and resilience | Stage 4 shared/integration nodes | Common treatment, safety contracts, checks, visual pass | Commands and review note | Covered |

## Node Registry

| Node file | Type | Parent file | Owns | Task-model basis | Children | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `stages/01-discovery/STAGE.md` | Stage | Project root | Baseline audit | Stage 1 definition | 3 task nodes | Complete |
| `stages/01-discovery/tasks/feature-flow-audit.md` | Task | `stages/01-discovery/STAGE.md` | Six shortcut flows | Complete current-state map | None | Complete |
| `stages/01-discovery/tasks/shared-surface-audit.md` | Task | `stages/01-discovery/STAGE.md` | Shared operational UI | Shared-surface audit | None | Complete |
| `stages/01-discovery/tasks/experience-critique.md` | Task | `stages/01-discovery/STAGE.md` | Critique and change list | Experience critique | None | Complete |
| `stages/02-design/STAGE.md` | Stage | Project root | Approved redesign | Stage 2 definition | 2 task nodes | Approved |
| `stages/02-design/tasks/visual-direction.md` | Task | `stages/02-design/STAGE.md` | Visual principles and priorities | Design direction | None | Complete |
| `stages/02-design/tasks/implementation-spec.md` | Task | `stages/02-design/STAGE.md` | Per-branch implementation plan | Single approval gate | None | Approved |
| `stages/03-research/STAGE.md` | Stage | Project root | Official pattern research | Stage 3 definition | 2 task nodes | Complete |
| `stages/03-research/tasks/liquid-glass-research.md` | Task | `stages/03-research/STAGE.md` | Official sources and compatibility | Apple research | None | Complete |
| `stages/03-research/tasks/pattern-mapping.md` | Task | `stages/03-research/STAGE.md` | Pattern-to-branch mapping | Research mapping | None | Complete |
| `stages/04-implementation/STAGE.md` | Stage | Project root | Code implementation and proof | Stage 4 definition | 8 task nodes | Complete |
| `stages/04-implementation/tasks/shared-foundation.md` | Task | `stages/04-implementation/STAGE.md` | Shared visual foundation | Shared foundation | None | Complete |
| `stages/04-implementation/tasks/feature-ocr.md` | Task | `stages/04-implementation/STAGE.md` | OCR branch | OCR implementation | None | Complete |
| `stages/04-implementation/tasks/feature-refine.md` | Task | `stages/04-implementation/STAGE.md` | Refine branch | Refine implementation | None | Complete |
| `stages/04-implementation/tasks/feature-translate.md` | Task | `stages/04-implementation/STAGE.md` | Translate branch | Translate implementation | None | Complete |
| `stages/04-implementation/tasks/feature-format.md` | Task | `stages/04-implementation/STAGE.md` | Format branch | Format implementation | None | Complete |
| `stages/04-implementation/tasks/feature-finder-path.md` | Task | `stages/04-implementation/STAGE.md` | Finder Path branch | Finder Path implementation | None | Complete |
| `stages/04-implementation/tasks/feature-explain.md` | Task | `stages/04-implementation/STAGE.md` | Explain/chat branch | Explain implementation | None | Complete |
| `stages/04-implementation/tasks/integration-verification.md` | Task | `stages/04-implementation/STAGE.md` | Build, source/state matrix, visual pass, and follow-up reconciliation | Verification | None | Complete |

## Order And Handoff Table

| Node | Follows or needs | Gate type | Unlock / handoff note | Status |
| --- | --- | --- | --- | --- |
| Stage 1 feature-flow audit | None | Work-order | Start from active cursor | Complete |
| Stage 1 shared-surface audit | Feature-flow audit | Work-order | Activate after feature inventory evidence | Complete |
| Stage 1 experience critique | Both Stage 1 audits | Work-order | Activate after both audit rows close | Complete |
| Stage 2 visual direction | Stage 1 complete | Work-order | Stage 1 parent closes | Complete |
| Stage 2 implementation spec | Visual direction | Work-order | Visual principles recorded | Approved |
| Stage 3 research | Stage 2 spec | Approval | User approval recorded | Complete |
| Stage 4 implementation | Stage 3 research | Work-order | Research/map complete; no extra hard gate | Complete |
| Stage 4 verification | Original feature nodes | Work-order | Feature evidence and delivered follow-up reconciliation recorded; owner-only review explicitly deferred | Complete |

## Parent-Child Context

| Parent | Child | Context carried into child | Why it matters locally | Closure note |
| --- | --- | --- | --- | --- |
| Stage 1 | Feature-flow audit | Six original actions; complete flow and meaningful states | Prevents sampling | Six feature rows complete |
| Stage 1 | Shared-surface audit | Menu-bar utility and fast flow | Shared UI is part of product | Shared rows complete |
| Stage 1 | Experience critique | Be hypercritical but simple | Converts facts into reasons/priorities | Change list complete |
| Stage 2 | Visual direction | Native, low-friction visual language | Prevents overdesign | Direction recorded |
| Stage 2 | Implementation spec | One approval gate after Stage 2 | Makes code scope explicit | User approval or deferments recorded |
| Stage 3 | Liquid Glass research | Official Apple sources only | Prevents unsupported styling | Sources and limits recorded |
| Stage 3 | Pattern mapping | Apply only to approved branches | Prevents scope expansion | Mapping complete |
| Stage 4 | Shared foundation | Shared tokens/components first | Keeps features coherent | Shared UI evidence |
| Stage 4 | Feature nodes | Preserve each feature contract | Allows independent proof | Each branch complete |
| Stage 4 | Integration verification | Build is not enough | Proves real behavior and visuals | Checks and review complete |

## Parent Closure Rules

| Parent node | Required children | Children allowed to defer? | Tracking or evidence required to close parent | Closure status |
| --- | --- | --- | --- | --- |
| Stage 1 | Feature-flow, shared-surface, experience-critique | Yes, with reason | Complete inventory, critique, and recorded deferred items | Complete |
| Stage 2 | Visual direction, implementation spec | Yes, with reason | Approved or explicitly deferred proposal rows; user gate resolved | Approved |
| Stage 3 | Liquid Glass research, pattern mapping | Yes, with reason | Official sources and selected mapping recorded | Complete |
| Stage 4 | Shared foundation, six feature nodes, integration verification | Yes, with reason | Build/check/source-state evidence recorded; owner-only runtime review explicitly deferred | Complete |

## Deferred Or Rejected Nodes

| Proposed node | Reason deferred / rejected | Revisit condition |
| --- | --- | --- |
| Separate settings-window rewrite | Not yet justified; current scope is visual/UX improvement, not architecture replacement | Stage 2 finds a concrete approved need |
| Further shortcut actions or provider/model redesign | Outside this closed plan; delivered follow-ups are already reconciled in verification | Human owner explicitly starts a new scoped task |

## Orphan And Closure Check

- [x] Every planned node file is registered below.
- [x] Every child file names a parent.
- [x] Every parent lists its child files.
- [x] Every node maps back to `TASK_MODEL.md`.
- [x] Work-order and approval gates have explicit unlock notes.
- [x] Parent closure rules account for every required child.
- [x] Lazy points have a static checklist or behavior-branch owner.
- [x] `MASTER_PROGRESS.md` records a closed cursor with no active node.
