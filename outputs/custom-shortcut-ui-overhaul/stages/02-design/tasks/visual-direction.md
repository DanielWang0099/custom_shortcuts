# Visual Direction and Priorities

Node type: Task
Status: Complete
Parent: `stages/02-design/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The visual principles, hierarchy, compact design system, and priority classification for the approved redesign.

Does not own:
- Official Apple citation collection, detailed file edits, or implementation approval.

Parent context:
- Favor native macOS clarity, quiet idle surfaces, quick recognition, and a small number of reusable visual treatments.

## Execution

Plan:
- Turn Stage 1 friction into visual principles and explicit must-have/should-have/deferred choices.
- Define hierarchy, spacing, type, symbols, color/material behavior, focus, feedback, and panel/menu treatment.
- Define target experience summaries for each of the six features and shared surfaces.

Done checks:
- [x] Principles address speed, clarity, accessibility, and visual coherence.
- [x] Priority choices have reasons and do not expand product scope.
- [x] All six feature targets and shared surfaces are represented.
- [x] Deferred ideas are recorded with a reason.

Guardrails:
- Avoid decorative complexity that makes the utility slower or harder to scan.
- Prefer a shared treatment over six bespoke visual systems.

## Visual Direction

### Product Character

The app should feel like a **quiet power tool**: immediately available, visually calm at rest, and decisive at the moment a shortcut completes. Native macOS conventions should do most of the work. The visual system should make the app's careful safety behavior visible without turning a fast utility into a dashboard.

### Hierarchy

1. **Action context and outcome** are primary. The user should know which shortcut is active and what happened.
2. **Readiness** is secondary. The menu should quickly answer whether shortcuts are enabled and what prerequisite is missing.
3. **Diagnostics** are tertiary. Raw last-status text and token details should remain available but not dominate the first glance.

### Shared Visual Rules

- Use system typography and semantic colors; do not invent a brand font or a saturated custom palette.
- Use a compact spacing rhythm: 8 points for related controls, 12 for grouped content, 16 for surface padding.
- Use rounded corners only for floating surfaces/HUDs, with one shared radius family rather than per-feature decoration.
- Use material/translucency only where it clarifies layering; preserve a solid, readable content surface for Explain transcript and input.
- Use SF Symbols with consistent weight and size. Symbols support labels; they do not replace labels.
- Make keyboard focus visible and ensure meaning does not depend on color alone.
- Keep transient feedback near the initiating context, concise, and nonactivating. Long explanations belong in the menu or panel, not a one-line HUD.
- Prefer one reusable component/treatment over six similar custom surfaces.

### Target Surface Direction

| Surface | Target experience | Design boundary |
| --- | --- | --- |
| Status menu | A compact “ready / working / needs attention” summary, a discoverable shortcut reference, then grouped readiness and maintenance actions | Keep it a menu-bar utility, not a full settings window |
| Translate/Format input | Same compact field geometry, but action title, action-specific placeholder, optional short context line, clear Return/esc behavior | Preserve one field, Enter submit, and focus-loss cancellation |
| HUD | Shared outcome vocabulary with stable icon/text hierarchy for copied, replaced, fallback-copied, cancelled, blocked, and failed | No notification center, no persistent content, no long diagnostic sentences |
| First-run/readiness | Short structured explanation followed by visible prerequisites and direct recovery actions | Preserve consent, billing warning, privacy warning, and no background polling |
| Explain panel | Clear “Explain” header, non-sensitive attached-selection state, differentiated user/answer transcript, quiet loading/retry, and intentional keyboard dismissal | Never render hidden selected text or add persistence |
| OCR/Finder feedback | Clear capture/fallback/result language using the shared treatment | Preserve OCR clipboard-only and Finder local-only contracts |

### Priority Recommendation

- **Must-have first pass:** status-menu discoverability/readiness hierarchy; contextual Translate/Format input; shared outcome language; Explain panel hierarchy.
- **Should-have if the same primitives support it:** structured first-run disclosure and permission readiness; OCR/Finder edge-state copy; shared focus/appearance/accessibility pass.
- **Deferred:** new shortcut editor, richer chat, persistent history, model/provider changes, settings-window rewrite, or new actions.

### Stage 2 Design Decision

Use the must-have first pass as the implementation baseline. Include the first-run/readiness and accessibility improvements if they can reuse the same shared hierarchy without creating a second settings surface. Keep all behavior contracts unchanged unless the implementation specification identifies a concrete safety or clarity issue for the user to approve.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Visual principles and priority map | Done | Visual direction and priority recommendation recorded above | Six feature targets + six shared surfaces mapped | Handoff to implementation specification |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
The visual direction names the small set of reusable rules and a priority for each proposed change.

Handoff rule:
Pass the direction to `implementation-spec.md`; do not begin code or external pattern research from this node alone.
