# Custom Shortcuts UI Overhaul — Master Progress

Status: **Complete** as of 2026-08-10.

This file is the closed execution cursor for the planning folder. The detailed stage and task files remain as historical evidence; no node is currently active.

## Current Cursor

| Field | Value |
| --- | --- |
| Active stage | None — workflow complete |
| Active node | None |
| Current status | Complete |
| Next action | Start a new scoped plan only if the user requests additional work |

## Active Node Chain

No execution node is active. The closed chain is Project → Stage 4 Implementation and Verification → Integration Verification, with each level marked Complete and the remaining owner-only pixel inspection listed under Deferred Items.

## Status Table

| Area | Delivered behavior | Evidence |
| --- | --- | --- |
| AI shortcuts | OCR, Refine, Translate, Format, Finder Path, Explain, and Calculate | `README.md`; `Sources/AIShortcutsCore/Domain.swift`; `Sources/AIShortcuts/AppDelegate.swift` |
| Local shortcuts | Input Lock, Sequential Clipboard, and Insert | `README.md`; `Sources/AIShortcuts/AppDelegate.swift`; local service/store files |
| Shared UI | Status menu, Shortcut Guide, onboarding/readiness, prompt panels, Explain composer, HUD feedback, and permission guidance | `Sources/AIShortcuts/StatusMenuController.swift`; `ShortcutGuideWindowController.swift`; `ShortcutUIStyle.swift`; controllers under `Sources/AIShortcuts/` |
| Safety and privacy | Selection replacement protection, clipboard fallback, hidden Explain context, image-memory limits, local-only values, budget guard, and process-owned event taps | `Sources/AIShortcutsCore/`; `Sources/AIShortcuts/`; `README.md` |

### Node Closure

| Node | Status | Closure evidence |
| --- | --- | --- |
| Stage 1 — Discovery | Complete | Feature-flow, shared-surface, and experience-critique nodes complete |
| Stage 2 — Design | Approved / Complete | User approval recorded; implementation specification closed |
| Stage 3 — Apple research | Complete | Official source record and compatible AppKit pattern map complete |
| Stage 4 — Implementation and verification | Complete | Shared UI, original six feature branches, follow-up shortcut additions, builds, checks, and source/state verification complete |

## Approval Gates

| Gate | Status | Note |
| --- | --- | --- |
| Stage 2 redesign and implementation specification | Approved | Explicit user approval recorded on 2026-08-10; all downstream work was completed inside the approved UI/safety direction |

No unresolved hard approval gate remains.

## Guardrail Register

- Preserve the fast menu-bar workflow and simple native AppKit architecture.
- Keep privacy, permission, budget, clipboard, selection, and hidden-context contracts intact.
- Keep screenshots, prompts, responses, and credentials out of logs and disk storage unless the existing local library contract explicitly requires storage.
- Do not reopen a completed node for a new feature request; create a new scoped plan or task instead.

## Evidence Notes

- `swift run AIShortcutsCoreChecks` — all checks pass.
- `swift build -c release` — release build passes.
- `Scripts/install.sh` rebuilt, packaged, signed, installed, and relaunched the app during the implementation pass.
- Source/state coverage exists for all ten registered shortcuts and the Shortcut Guide.
- Prompt, Explain, HUD, input-lock, clipboard-queue, Finder, and status-menu behavior received source or interactive review where the environment allowed it.

## Deferred Items

| Item | Reason | Revisit condition |
| --- | --- | --- |
| Owner-controlled Finder Automation consent and final cross-app path check | Requires the human owner to approve macOS Automation access and exercise Finder directly | User asks for a runtime permission/acceptance pass |
| Pixel-level status-menu review in every appearance/accessibility variant | Requires interactive owner/environment review; implementation and source evidence are complete | User requests a visual QA pass |
| Persistent always-on-top behavior for other apps | No supported public macOS API provides this without private APIs or disruptive polling | A supported platform API or explicit scope change becomes available |

These are explicit deferrals, not active blockers to the completed implementation.

## Next Node Queue

| Order | Node | Gate | Status |
| --- | --- | --- | --- |
| 1 | None; create a new scoped task for later product requests | Explicit new user request | Closed |

## Historical Handoff

The original recursive plan covered the six-action UI overhaul. Later work added Calculate, Explain image paste, Input Lock, Sequential Clipboard, Insert, Shortcut Guide, Finder remapping, and related resilience fixes. Those follow-ups are recorded in the Stage 4 integration-verification node and are included in the closure above.

## Completion Rule

The planning workflow is complete because every required node is Complete, Approved, or explicitly Deferred with a reason; the Stage 2 approval is resolved; release checks pass; current shortcut coverage is recorded; and no required execution node remains active.
