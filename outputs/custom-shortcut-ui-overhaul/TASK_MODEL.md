# Custom Shortcuts UI Overhaul - Execution Plan

This is the detailed plan for improving the app's visual quality and user experience while preserving its fast menu-bar workflow. It was written after both definition checkpoints were explicitly approved and is now closed. The original plan covered six AI actions; later delivered follow-ups are reconciled below rather than treated as active work.

## Approved Two-Step Definition

### Step 1 - Structure Approval

Approved on 2026-08-10.

#### Stages

- **Current-state discovery and feature-flow audit** - map and challenge every user-facing flow.
- **Approved visual/UX direction and implementation specification** - turn the audit into prioritized, approval-ready changes.
- **Official Apple UI research and pattern mapping** - connect approved changes to current official macOS patterns.
- **Implementation and verification** - implement and prove the approved changes.

#### Subtasks

- **Stage 1:** inventory entry points and shared surfaces; audit OCR, Refine, Translate, Format, Finder Path, Explain/chat; audit shared operational states; produce critique and approval-ready change list.
- **Stage 2:** define visual hierarchy and target experiences; prioritize scope; write behavior-branch implementation plan; present the one hard approval gate.
- **Stage 3:** research official Liquid Glass and AppKit patterns; check compatibility; map patterns and templates to approved branches.
- **Stage 4:** implement shared foundation, onboarding/menu/settings/permissions, the six original feature branches, and integration/resilience verification.

### Step 2 - Detail Approval

Approved on 2026-08-10, with the instruction to keep lazy-point tracking simple.

#### Stages

- **Stage 1:** baseline audit only; no code changes or new product scope.
- **Stage 2:** approved visual direction and implementation specification; no coding before the gate.
- **Stage 3:** relevant official research only, grounded in the existing AppKit/macOS constraints.
- **Stage 4:** approved implementation and verification only; avoid unrelated refactors.

#### Subtasks

- Cover the six original actions and shared surfaces, with meaningful prerequisite, busy/cancel, success, failure, and feature-specific safety states.
- Define a compact visual language and per-feature target states, then map every must-have to a component/behavior branch and verification method.
- Record official Apple sources, access dates, platform constraints, and pattern-to-branch mappings.
- Implement shared treatment first, then onboarding/shared operations, then OCR, Refine, Translate, Format, Finder Path, Explain/chat, and final verification.

#### Lazy Points

- **Coverage shortcut** -> inventory evidence accounts for the six original actions plus every shared surface; follow-up actions are reconciled in Stage 4 verification.
- **Happy-path shortcut** -> each feature records its applicable prerequisite, busy/cancel, success, and failure or unsupported states.
- **Concept-only shortcut** -> every approved change maps to a component/branch, affected state, and verification method.
- **Unofficial-pattern shortcut** -> every adopted Apple pattern has an official source and compatibility note.
- **Build-only shortcut** -> existing checks pass and the original features plus delivered follow-ups receive source/state or manual review evidence.

## Goal

Deliver a noticeably better-looking, more native-feeling custom shortcut app whose actions are easier to discover and trust, whose transient feedback and panels are coherent, and whose interactions remain quick and responsive. The work should improve the product's visual hierarchy and clarity without adding needless complexity or changing the app's core safety/privacy behavior.

## Expected Outputs

| Output / outcome | What it should contain | What good work looks like | Small evidence note |
| --- | --- | --- | --- |
| Current-state audit | Complete feature/surface inventory, flow notes, state coverage, critique, and candidate changes | A later run can see exactly what each action does and where the current experience falls short | Stage 1 node outputs and tracking evidence |
| Approved redesign specification | Prioritized changes, visual principles, target states, scope boundaries, and per-branch implementation units | The user can approve a concrete plan without guessing what will change | Stage 2 approval note in `MASTER_PROGRESS.md` |
| Apple pattern map | Official URLs, access dates, compatibility notes, selected patterns, and code-template guidance | Each adopted pattern is both supported and tied to an approved change | Stage 3 research node |
| Implemented UI/UX improvements | Shared visual foundation, updated surfaces, original feature branches, and necessary supporting behavior | App feels coherent and native while existing contracts remain intact | Build and code diff in Stage 4 |
| Verification record | Build/check results, feature/state matrix, visual review, limitations, and deferred items | Completion claims are backed by actual evidence rather than compilation alone | Stage 4 verification node and `MASTER_PROGRESS.md` |

## Execution Plan

1. **Discover from the real app.** Read the README, Package manifest, AppKit controllers, core domain/prompt contracts, and tests. Run the available build/check commands and launch or inspect the app when possible. Trace the original six shortcuts from trigger through input capture, AI/local processing, result delivery, and feedback. Record the actual behavior, not an idealized interpretation.
2. **Audit shared surfaces and states.** Treat the menu bar, first-run disclosure, permissions, key/budget status, restart/cancel, HUD, busy state, and errors as part of the product. Identify inconsistent or noisy UI, places where users lack context, and places where speed is compromised.
3. **Critique and propose.** For each feature, state the user goal, current friction, desired experience, proposed change, reason, risk, and priority. Keep proposals small and preserve the feature's existing safety contract. Finish Stage 1 with a concise approval-ready change list.
4. **Specify the approved design.** Define a compact visual language and target state map. Convert each must-have into a branch that names affected files/components, behavior states, caller/contract constraints, and proof. Record should-have/deferred items so they do not leak into implementation. Present the only hard gate here: explicit user approval of the Stage 2 redesign and implementation specification.
5. **Research after approval.** Use official Apple documentation and examples for Liquid Glass, materials, menus, panels, controls, typography, symbols, focus, accessibility, and transient feedback. Check the macOS 13 deployment target and the actual AppKit architecture. Map research to approved branches; do not turn research into an excuse for scope expansion.
6. **Implement progressively.** Update shared visual tokens/components and common surfaces first. Then implement the six original feature branches independently, including the state/error behavior they own. Reconcile later delivered additions—Calculate, Explain image paste, Input Lock, Sequential Clipboard, Insert, Shortcut Guide, Finder remapping, and resilience fixes—in the final verification record. Preserve clipboard fallback, unchanged-selection protection, hidden Explain selection, permission checks, budget guard, and privacy/logging rules.
7. **Verify and hand off.** Run `swift run AIShortcutsCoreChecks` and `swift build -c release`, review the original features plus delivered follow-ups, inspect visual consistency, and record any environment limitations. Close parents only after their children have complete evidence or explicit deferrals.

## Approvals And Consequential Actions

| Action or decision | When it matters | Who decides | Default if unresolved | Where tracked |
| --- | --- | --- | --- | --- |
| Approve the Stage 2 redesign and implementation specification | Before Stage 3 research is used to guide implementation and before Stage 4 code changes | Human owner | Keep Stage 3 and Stage 4 locked; do not infer approval from silence | `MASTER_PROGRESS.md#approval-gates` |
| Select a pattern when official Apple guidance leaves multiple viable options | During Stage 3 mapping | Codex within approved scope | Choose the simplest compatible native option and record the rationale; do not add a new hard gate | Stage 3 research/mapping node |
| Defer a proposal that expands product scope | Any stage | Codex records; human may later revive | Defer with reason and preserve current behavior | Relevant node and `MASTER_PROGRESS.md` |

No other hard approval gates are required after the Stage 2 approval. Work-order sequencing and evidence checks still apply.

## Details Later Runs Must Not Lose

| Detail | Why it matters | Where to preserve it |
| --- | --- | --- |
| Simplicity is the governing preference | Prevents over-designed panels, settings, and planning overhead | `PROJECT_BRIEF.md`, all stage nodes |
| The app's core promise is quick, responsive shortcut execution | A visually rich change that slows the flow is a regression | `PROJECT_BRIEF.md`, Stage 2 and Stage 4 nodes |
| The original actions are OCR, Refine, Translate, Format, Finder Path, and Explain/chat; the current product also includes Calculate, Input Lock, Sequential Clipboard, and Insert | Coverage must be complete and independently verifiable | Stage 1 and Stage 4 nodes |
| Refine/Format must not replace a changed selection; results fall back to clipboard | UI changes must preserve safety behavior | Stage 1 feature audits, Stage 4 nodes |
| Explain attaches selected text invisibly and keeps chat content transient | Do not render hidden context or introduce persistence | Stage 1 and Stage 4 Explain nodes |
| Existing API key, permission, budget, and privacy behavior is not redesign scope by default | Operational UI can improve without changing policy | `PROJECT_BRIEF.md`, shared-surface node |
| Apple research must be official and compatibility-aware | Prevent unsupported Liquid Glass styling or wrong deployment assumptions | Stage 3 nodes |
| Only one hard approval gate exists after Stage 2 | Later execution should not pause for invented approvals | `MASTER_PROGRESS.md#approval-gates` |
| The planning workflow is closed | New requests must start a new scope instead of reopening completed nodes | `MASTER_PROGRESS.md` |

## Task-To-Node Trace

| Request / output / constraint | Node(s) responsible | What the node must describe well | Small evidence note | Status |
| --- | --- | --- | --- | --- |
| Complete current-state map | `stages/01-discovery/tasks/feature-flow-audit.md`, `shared-surface-audit.md` | Six original feature flows and shared operational surfaces | Source/runtime notes and coverage count | Covered |
| Challenge current UI/UX and list changes/reasons | `stages/01-discovery/tasks/experience-critique.md` | Friction, user goal, priority, rationale, and final gate | Audit artifact and change list | Covered |
| Make implementation steps clearer after audit | `stages/02-design/tasks/implementation-spec.md` | Component, behavior branch, state coverage, and proof per approved change | Approval-ready Stage 2 specification | Covered |
| Research official Liquid Glass/native UI patterns | `stages/03-research/tasks/liquid-glass-research.md` | Official sources, dates, APIs, compatibility limits | URL/source record | Covered |
| Match patterns to implementation | `stages/03-research/tasks/pattern-mapping.md` | Pattern-to-branch decisions and rationale | Mapping table | Covered |
| Implement every approved feature branch and reconcile delivered follow-ups | `stages/04-implementation/tasks/shared-foundation.md`, feature nodes, and `integration-verification.md` | Shared UI plus original AI branches, Calculate, local shortcuts, Explain images, guide, and resilience fixes | Build/check/source-state evidence | Covered |
| Preserve post-plan shortcut additions | `stages/04-implementation/tasks/integration-verification.md` | Calculate, Input Lock, Sequential Clipboard, Insert, Shortcut Guide, and their privacy/permission contracts | Follow-up verification notes, checks, release install | Covered |
| Keep it simple and preserve quick flow | All nodes; gate in `MASTER_PROGRESS.md` | Scope boundaries and no unnecessary complexity | Deferred list and final review | Covered |

## Recursive Split Notes

- Stage nodes exist for the four approved phases.
- Stage 1 splits feature-flow, shared-surface, and critique work because each can be partially complete and needs separate evidence.
- Stage 2 splits visual direction from implementation specification because the latter owns the single approval-ready contract.
- Stage 3 splits source research from pattern mapping so citations are not confused with design decisions.
- Stage 4 gives each shortcut its own implementation node because each has independently verifiable states and safety contracts; shared foundation and integration verification remain separate.
- No extra subtask level is added because the plan is intentionally simple and the leaf nodes already represent meaningful focused passes.
- Stage 1 -> Stage 2 and Stage 3 -> Stage 4 are work-order gates. Stage 2 -> Stage 3/4 is the single hard approval gate.

## Plan Completion Note

This plan is complete and the recursive node files below carry the historical scope, behavior branches, evidence, and handoff rules. No node is active; future requests require a new scoped plan.
