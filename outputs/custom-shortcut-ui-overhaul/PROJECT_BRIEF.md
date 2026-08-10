# Custom Shortcuts UI/UX Plan — Project Brief

## Stable Intent

Improve the visual quality and overall experience of the native macOS custom shortcut app while preserving its strongest product quality: fast, responsive, low-friction execution. The work should be proactive and critical about the current UI, but remain simple and focused. Simplicity is the governing preference. This plan is now closed; the implementation and later follow-up additions are recorded as delivered or explicitly deferred.

The result should make every offered feature easier to understand, more polished to use, and more coherent with macOS without turning a lightweight menu-bar utility into a complicated application.

## Source Inputs

- Repository: `/Users/susanawang/Documents/GitHub/custom_shortcuts`
- Product behavior and user-facing feature list: `README.md`
- Build and deployment constraints: `Package.swift`
- AppKit implementation: `Sources/AIShortcuts/`
- Core actions, prompts, contracts, and policies: `Sources/AIShortcutsCore/`
- Existing behavioral checks: `Tests/AIShortcutsCoreTests/CoreChecks.swift`
- Official Apple documentation and examples gathered during Stage 3, with URLs and access dates recorded in the research node.

## Scope

Original approved scope:

- The six shortcut actions: OCR, Refine, Translate, Format, Finder Path, and Explain/chat.
- Shared surfaces: menu-bar menu, first-run disclosure, permission guidance, API-key status/reload, budget status, restart, cancel, HUD feedback, and launch behavior.
- Current-state flow analysis, visual/UX critique, approved redesign, official Apple pattern research, implementation, and verification.
- UI code and narrowly necessary supporting behavior required to make the approved experience coherent and safe.

Delivered follow-up scope:

- Calculate screenshot analysis, including broad conversions and structure-preserving output.
- Explain image paste, Input Lock, Sequential Clipboard, Insert, Shortcut Guide, Finder remapping, and related resilience fixes.

Not part of the original approval and still outside this closed plan:

- Further product features, model/provider changes, analytics, unrelated refactors, or changes to privacy/safety contracts.
- Broad rewrite of the AppKit architecture solely for stylistic reasons.

## Important Boundaries

- Preserve the quick, responsive interaction model.
- Keep the plan and implementation simple; do not create process overhead for its own sake.
- There is one hard approval gate: the user approves the Stage 2 redesign and implementation specification. Stage 3 research and Stage 4 implementation do not require additional hard approval gates once that scope is approved.
- Preserve existing contracts such as unchanged-selection replacement safety, clipboard fallback, hidden selected text in Explain, permission prerequisites, local budget guard, and no sensitive-content logging.
- Use official Apple sources for current Liquid Glass and native macOS UI guidance; record compatibility constraints before adopting patterns.
- If research suggests a material scope expansion, record it as deferred rather than silently expanding the approved work.

## Definition Of Done

| Done means | Small evidence note | Owner |
| --- | --- | --- |
| All original actions and shared surfaces have an evidence-backed flow and UI/UX critique | Stage 1 audit artifacts and node evidence | Codex |
| A prioritized redesign and per-branch implementation specification is approved | User approval recorded in `MASTER_PROGRESS.md` | Human owner |
| Adopted Apple patterns are official, compatible, and mapped to approved changes | Stage 3 research URLs, access dates, and mapping | Codex |
| Approved UI changes and delivered follow-ups are implemented without breaking core contracts | Build, existing checks, and feature/state verification | Codex |
| Final visual pass confirms coherent hierarchy, feedback, and macOS-native polish | Review note in Stage 4 verification node | Codex + human review if available |

## Roles

| Role | Responsibilities | Approval / handoff authority |
| --- | --- | --- |
| Codex | Inspect, critique, research, plan, implement, test, and maintain the planning cursor | Can complete research and implementation inside approved scope |
| Human owner | Decide the Stage 2 redesign scope and review the finished experience | Sole hard approver before research-to-implementation execution |

## Detail Preservation Rules

- Keep the full execution reasoning in `TASK_MODEL.md`; do not compress it into the final prompt.
- Keep current status, evidence, and the single approval gate in `MASTER_PROGRESS.md`.
- Keep per-feature behavior branches in their owning node files.
- Treat README and source behavior as the baseline; record any discrepancy discovered during runtime inspection.
- Use screenshots or other visual evidence when available, but do not claim runtime validation if the app cannot be launched in the available environment.

## Final Codex Goal Prompt

```text
This plan is complete. Read /Users/susanawang/Documents/GitHub/custom_shortcuts/outputs/custom-shortcut-ui-overhaul/OPERATING_INDEX.md, PROJECT_BRIEF.md, TASK_MODEL.md, TASK_ARCHITECTURE.md, and MASTER_PROGRESS.md for the historical implementation record and current delivered baseline. Do not reopen completed nodes or treat deferred owner-only checks as implementation blockers. If the user requests new behavior, research, or QA, create a new scoped task with its own approval and progress cursor, preserve the existing quick native workflow and safety/privacy contracts, and verify changes with the project checks and release build.
```
