# Experience Critique and Candidate Change List

Node type: Task
Status: Complete
Parent: `stages/01-discovery/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- A concise, hypercritical but practical critique of the current UI/UX and a prioritized list of possible changes with reasons and risks.

Does not own:
- Coding, official research, or final approval of the redesign.

Parent context:
- The user wants better-looking UI while keeping the existing quick flow. Simplicity outranks feature breadth and ornamental complexity.

## Execution

Plan:
- Combine both Stage 1 audits into a user-goal/friction matrix.
- Challenge hierarchy, discoverability, visual polish, accessibility, timing, cognitive load, consistency, and trust.
- Classify changes as must-have, should-have, or deferred, and state what each change improves.
- End with the exact questions the Stage 2 plan must answer.

Done checks:
- [x] Every six-feature row and shared-surface finding is represented or explicitly deprioritized.
- [x] Each proposed change has a reason, risk, priority, and likely owner surface.
- [x] Deferred scope is recorded rather than silently carried into implementation.
- [x] Stage 2 has enough detail to define an approval-ready redesign.

Guardrails:
- Do not turn taste preferences into requirements without connecting them to user goals or evidence.
- Do not add a second hard approval gate; Stage 2 owns the single approval decision.

## Audit Findings

### Diagnosis

The app's behavioral layer is more mature than its visible experience. Selection safety, permission gates, token budgeting, retry handling, and transient chat memory are deliberate and tested. The UI exposes that strength poorly: the status menu is mostly disabled diagnostics, the six actions are absent from the menu, parameter entry is unlabeled, and most outcomes disappear into a short pointer-adjacent HUD. The redesign should therefore improve hierarchy, context, and outcome clarity before adding any new capability.

### Prioritized Change List

| Priority | Proposed change | Why it matters | Risk / boundary | Evidence |
| --- | --- | --- | --- | --- |
| Must-have | **Make the six shortcuts discoverable from the status menu.** Add a quiet feature reference with action names and current hotkeys, while keeping the menu primarily a readiness surface. | Users currently need the README or memory to discover OCR, Refine, Translate, Format, Finder Path, and Explain. A shortcut utility should teach itself at the point of use. | Menu can become crowded; keep feature rows compact and avoid duplicating full command flows. Do not change hotkey mappings. | `StatusMenuController.swift:40-87` has no action list; `Domain.swift:3-55` defines all six actions and hotkeys. |
| Must-have | **Give Translate and Format a contextual one-field input surface.** Add action name, specific placeholder/instruction, and consistent submit/cancel affordance without adding a step. | The current 420x44 blank field is the highest-friction moment: the user must remember which action was triggered and what kind of instruction to type. | Keep the existing one-field/Enter/focus-loss flow; do not create a general settings form or persistent prompt history. | `PromptPanelController.swift:11-105`; `AppDelegate.swift:360-383`. |
| Must-have | **Unify outcome language and hierarchy.** Distinguish copied, replaced, fallback-copied, cancelled, blocked, failed, and no-readable-content outcomes with concise, stable wording. | Refine/Format can safely produce different result destinations, but the current transient message is easy to miss or too vague. Trust depends on knowing what happened. | Keep feedback transient and nonactivating; no notification center or logging of content. | `AppDelegate.swift:287-342,401-420,655-687`; `HUDController.swift:18-78`. |
| Must-have | **Reframe readiness around “what can run now?”** Group enablement, Accessibility, Screen Recording, Automation, API key, and budget by user impact, with direct recovery actions. | Current status rows are technically accurate but flat. Users see diagnostics rather than a clear path to readiness. | Preserve existing privacy/consent and permission semantics; do not add background polling. Finder Automation remains relevant only to Finder Path. | `StatusMenuController.swift:45-87`; `AppDelegate.swift:120-194,241-259,337-348`. |
| Must-have | **Strengthen Explain's compact panel hierarchy.** Keep hidden selection private, but add clear title/context state, stronger user/answer separation, loading/retry clarity, and an intentional dismissal affordance. | Explain is the richest feature and currently looks like an opaque text surface. The privacy behavior is good; the user-facing trust signal is weak. | Preserve one-panel chat, no persistence, bounded memory, focus-loss behavior unless Stage 2 explicitly changes it. | `ExplanationPanelController.swift:1-362`; `AppDelegate.swift:424-540`; memory checks passed. |
| Should-have | **Shorten and structure first-run disclosure.** Present the same consent/privacy/billing facts in a compact hierarchy with a clear next action and a visible permission checklist after confirmation. | The current modal is responsible but cognitively heavy and hides the onboarding sequence in prose. | Do not weaken the confirmation requirement or alter data-sharing meaning. | `AppDelegate.swift:133-163`. |
| Should-have | **Improve OCR and Finder Path state explanations.** Make crop cancellation, no-readable-text, Finder fallback, Automation denial, and local-only behavior easier to understand. | These features are fast but their edge states are currently silent or only briefly described. | Keep OCR clipboard-only and Finder Path local-only; no extra confirmation step for successful use. | `AppDelegate.swift:287-342`; `ScreenshotService.swift:25-96`; `FinderSelectionService.swift:24-101`. |
| Should-have | **Add native focus/accessibility/appearance polish as a shared pass.** Check labels, keyboard focus, light/dark contrast, menu typography, panel sizing, and reduced visual noise. | The code creates custom AppKit surfaces without an explicit shared accessibility or appearance contract. | Use native controls/materials where they meet the goal; avoid a broad AppKit-to-SwiftUI rewrite. | `PromptPanelController.swift:20-70`; `ExplanationPanelController.swift:115-238`; `HUDController.swift:35-78`. |
| Deferred | **Custom hotkey editor, persistent history, richer chat, new actions, model/provider changes, settings-window rewrite.** | These may be useful products but are not required to make the current utility look and feel better. | Out of scope unless the human owner explicitly expands scope. | `PROJECT_BRIEF.md` scope boundary and `TASK_MODEL.md` deferred rules. |

### Stage 2 Decision Set

Stage 2 should turn the Must-have and selected Should-have rows into an approval-ready specification by deciding:

1. The compact menu hierarchy: where feature discovery sits relative to readiness and operations.
2. The exact reusable input surface for Translate/Format and which outcome messages are shared versus feature-specific.
3. The Explain panel's minimum visual hierarchy that improves trust without exposing hidden context or adding persistence.
4. Whether first-run disclosure and permission readiness are part of the first implementation pass or remain a smaller follow-up.
5. The exact AppKit components/materials to research and adopt after approval.

The recommended default is to approve all five Must-have changes, approve the first two Should-have changes if they fit the same shared components, and defer the rest until the visual foundation is proven.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Critique and prioritized change list | Done | Prioritized change list and Stage 2 decision set recorded above | Five Must-have, three Should-have, three Deferred items | Handoff to Stage 2 visual direction |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
The change list is complete, prioritized, evidence-linked, and explicit about what is deferred or out of scope.

Handoff rule:
Unlock Stage 2 visual direction and carry forward the change list as the only design input that needs to survive this stage.
