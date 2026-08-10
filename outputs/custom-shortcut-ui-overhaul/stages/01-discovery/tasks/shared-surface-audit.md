# Shared-Surface Audit

Node type: Task
Status: Complete
Parent: `stages/01-discovery/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The menu-bar menu, first-run disclosure, permission guidance, API-key status/reload, budget status, restart, cancel, HUD feedback, and launch behavior.

Does not own:
- Detailed six-feature flows, final redesign, Apple research, or implementation.

Parent context:
- Shared surfaces are part of the product experience, but the app should remain a lightweight utility with quiet idle behavior.

## Execution

Plan:
- Read `StatusMenuController`, `AppDelegate`, `HUDController`, state/keychain/configuration code, README, and tests.
- Record what users see, what they can infer, and where feedback is delayed, noisy, ambiguous, or inconsistent.
- Include prerequisite and recovery paths for permissions, key, budget, busy, cancel, and restart.

Done checks:
- [x] Every listed shared surface has an evidence-backed observation.
- [x] Recovery and error paths are included where applicable.
- [x] Findings are concise enough to guide Stage 2 rather than becoming a settings redesign.

Guardrails:
- Preserve policy and privacy meaning; critique presentation and interaction unless a behavior change is explicitly justified in Stage 2.

## Audit Findings

Source evidence is from the current AppKit controllers and launch flow. The app was not launched during this audit because doing so would trigger persistent data-sharing and macOS permission state changes; runtime visual claims remain for Stage 4.

| Surface | Current state | User need | Critical finding |
| --- | --- | --- | --- |
| Menu-bar status menu | Rebuilds on open and shows Ready/Working, GPT-5.4, budget remaining, API-key status, last API status, enablement/data settings, permission rows, reload key, and restart. Evidence: `Sources/AIShortcuts/StatusMenuController.swift:20-132`, `Sources/AIShortcuts/AppDelegate.swift:120-130`. | Know whether the utility is ready and discover what it can do. | The menu is a diagnostic/status list, not a feature launcher or shortcut reference. None of the six actions or their Control-Option-Command hotkeys are discoverable in the app. Several rows are disabled text, so the visual hierarchy is flat and information-dense. |
| First-run disclosure | A blocking warning alert explains OpenAI sharing, project enrollment, billing risk, privacy warning, and the local budget; buttons are I Confirm, Open Data Settings, and Not Now. Evidence: `Sources/AIShortcuts/AppDelegate.swift:86-163`. | Make an informed choice without reading a wall of policy text in a transient alert. | The content is responsible but overlong for a first interaction and does not stage the decision into “what happens / what you need / continue.” The important next step is buried in paragraphs, and the success feedback after confirmation is only a checkmark HUD. |
| Permissions | On confirmation, Accessibility is requested, then Screen Recording 1.5 seconds later. Missing permissions later open the relevant System Settings pane and show a HUD error. Finder Automation is handled only when Finder Path fails. Evidence: `Sources/AIShortcuts/AppDelegate.swift:165-194,251-259,337-348`. | Understand which permission unlocks which shortcut and recover quickly. | The app has the right routing but not a clear readiness map. A user cannot see “OCR needs Screen Recording” or “text actions need Accessibility” in one glance, and Automation is absent until failure. |
| API key and budget | Menu shows API key Ready/Missing, full-model remaining tokens, and last API status; Reload API Key uses the HUD. Budget refusal is a long HUD sentence. Evidence: `Sources/AIShortcuts/StatusMenuController.swift:45-58`, `Sources/AIShortcuts/AppDelegate.swift:196-219,543-565`. | Know whether a shortcut can run and why it did not. | Status is technically available but not prioritized. “Last API status: Error” has little recovery value, while budget copy is too long for the one-line HUD and can be truncated. The readiness surface should answer “what can I use now?” rather than expose raw diagnostics first. |
| Busy/cancel/restart | Busy changes the status icon to `ellipsis.circle`, adds Cancel Current Operation to the menu, and shows “Working” only when a second action is attempted. Restart exits the process directly. Evidence: `Sources/AIShortcuts/StatusMenuController.swift:32-48,124-132`, `Sources/AIShortcuts/AppDelegate.swift:237-239,620-687`. | Trust that the shortcut is active, cancel safely, and understand when it is ready again. | The initial operation has no app-owned immediate feedback except the tiny icon change. Cancel is discoverable only by reopening the menu. A direct restart action has no confirmation or explanation, which is acceptable for a developer utility but not polished. |
| HUD feedback | Borderless, nonactivating, mouse-ignored HUD appears near the pointer with an SF Symbol and one line; success lasts 0.8 seconds, busy 1 second, errors 3.5 seconds and truncate to one line. Evidence: `Sources/AIShortcuts/HUDController.swift:1-92`. | Get a quick, unambiguous result without losing focus. | The placement and short duration suit the product, but the system has too many outcome messages for one transient line: copied vs replaced vs fallback-copied vs cancelled vs permission vs budget. It lacks a shared message hierarchy and cannot support a useful next action. |
| Translate/Format input panel | A 420x44 borderless floating panel with a single unlabeled text field appears after selection capture; Enter submits and focus loss cancels. Evidence: `Sources/AIShortcuts/PromptPanelController.swift:11-105`, `Sources/AIShortcuts/AppDelegate.swift:360-383`. | Provide a tiny instruction without interrupting the source app. | Fast but context-free. There is no title, placeholder, action label, selected-text state, or distinction between Translate and Format. Empty submit/focus loss can end the operation with no feedback. This is the highest-value shared UI fix. |
| Launch and accessory behavior | App uses accessory activation, a single-instance lock, status item setup, key import, hotkey registration, then first-run/permission routing. Evidence: `Sources/AIShortcuts/AppDelegate.swift:52-97`. | Feel like a reliable utility that is there when needed and quiet otherwise. | The architecture is appropriately lightweight. The user-facing state transition after install/update is not visible as a compact checklist, and a failed hotkey registration is only a HUD/log event. |

## Shared-Surface Design Implications

1. Add a quiet, discoverable shortcut reference to the menu without turning every action into a competing menu command.
2. Reframe the menu around readiness first: enablement, permissions, API key, budget, and current operation should answer “can I use this now?”
3. Replace the unlabeled parameter field with a reusable contextual input surface that names the action and uses action-specific placeholder/help text while preserving Enter-to-submit and focus-loss cancellation.
4. Establish a small outcome vocabulary and visual hierarchy for copied, replaced, fallback-copied, cancelled, blocked, and failed states.
5. Keep the HUD transient and nonactivating, but make important outcomes readable enough to trust; avoid turning it into a notification system.
6. Shorten and structure first-run disclosure without weakening the privacy/billing warning or consent requirement.
7. Treat launch/update and permission recovery as one readiness story rather than separate technical diagnostics.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Menu and status summary | Done | Source-backed critique recorded above | `StatusMenuController.swift:20-132`; no shortcut list present | Continue to onboarding |
| Onboarding and permissions | Done | Source-backed critique recorded above | `AppDelegate.swift:86-194,251-259,337-348` | Continue to readiness |
| API key and budget | Done | Source-backed critique recorded above | `StatusMenuController.swift:45-58`; `AppDelegate.swift:196-219,543-565` | Continue to operation states |
| HUD, busy, cancel, restart | Done | Source-backed critique recorded above | `HUDController.swift:1-92`; `AppDelegate.swift:620-687` | Continue to launch |
| Launch behavior | Done | Source-backed critique recorded above | `AppDelegate.swift:52-97`; runtime launch deferred to Stage 4 | Handoff to experience critique |

## Child Nodes

No child nodes. The five rows are the complete shared-surface inventory for this scope.

## Completion And Handoff

Completion rule:
All five rows are resolved with source/runtime evidence or a clearly recorded environment limitation.

Handoff rule:
Pass the shared-surface findings and open questions to `experience-critique.md`; do not start Stage 2 until this node and the feature-flow audit are complete.
