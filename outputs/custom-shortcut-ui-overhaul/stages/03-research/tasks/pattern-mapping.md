# Pattern-to-Implementation Mapping

Node type: Task
Status: Complete
Parent: `stages/03-research/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- The practical mapping from official Apple patterns to the approved shared and per-feature implementation branches.

Does not own:
- New visual proposals, broad platform experimentation, or code edits.

Parent context:
- The Stage 2 specification is the boundary. Research may refine implementation choices but may not silently expand approved scope.

## Execution

Plan:
- Review the approved branch list and the official source record.
- For each branch, select the simplest compatible native pattern or record why no direct pattern should be adopted.
- Note AppKit versus targeted SwiftUI decisions only when justified by the approved scope.
- Record reusable tokens/components and code-template guidance for Stage 4.

Done checks:
- [x] Shared foundation and all six feature branches have a pattern decision or explicit no-change rationale.
- [x] Every decision points to a source or the approved existing behavior.
- [x] Compatibility and scope constraints are visible to implementers.

Guardrails:
- Do not turn a pattern preference into an unapproved feature.
- Prefer native AppKit continuity when it satisfies the target experience.

## Pattern Mapping

The Stage 2 specification remains the boundary. The Apple research adds implementation constraints and native choices; it does not add a new surface, action, persistence layer, or framework migration.

### Shared patterns

| Approved branch | Official pattern | Implementation decision | Scope / compatibility note |
| --- | --- | --- | --- |
| Shared visual foundation | [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials), [`NSVisualEffectView`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview?changes=__7_5), [AppKit accessibility](https://developer.apple.com/documentation/%61ppkit/accessibility-for-appkit) | Add a small AppKit style helper for semantic colors, system fonts, spacing, panel dimensions, and reusable material setup. Use standard controls wherever possible; label custom panels. | Keep the existing AppKit/macOS 13 baseline. Do not add SwiftUI or Liquid Glass-specific APIs. |
| Status menu and readiness | [`NSStatusItem`](https://developer.apple.com/documentation/%61ppkit/nsstatusitem?changes=_4), [`NSStatusBar`](https://developer.apple.com/documentation/%61ppkit/nsstatusbar?changes=_5), [Menus HIG](https://developer.apple.com/design/human-interface-guidelines/menus), [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Keep the existing status item and `NSMenu`. Add a compact six-action reference, use native menu grouping/separators, and show concise readiness labels. Preserve all existing callbacks and hotkey mappings. | Status items are space-constrained; avoid a custom popover or decorative glass menu. The reference rows are for discoverability, not duplicate execution paths. |
| First-run and permission readiness | [`NSAlert`](https://developer.apple.com/documentation/%61ppkit/nsalert), [AppKit accessibility](https://developer.apple.com/documentation/%61ppkit/accessibility-for-appkit) | Keep the native alert and its explicit confirmation gate. Shorten the copy into readable paragraphs, preserve privacy/billing/permission disclosure, and keep current System Settings destinations. | No polling, settings-window rewrite, or new consent mechanism. |
| Shared outcome feedback | [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials), [`NSVisualEffectView`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview?changes=__7_5), [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Keep the pointer-adjacent nonactivating HUD. Use a semantic HUD material, system colors, short state-specific copy, and the existing timed dismissal. Put long diagnostics in the status menu or Explain surface. | The HUD is a functional transient layer; content is not made translucent and no notification system is introduced. |
| Contextual text input | [`NSVisualEffectView`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview?changes=__7_5), [AppKit accessibility](https://developer.apple.com/documentation/%61ppkit/accessibility-for-appkit) | Keep the borderless AppKit panel, one `NSTextField`, Return submit, Escape/focus-loss cancel, and visible first responder. Add an action label and action-specific placeholder/helper copy. | One-field geometry and quick flow remain intact. Use standard text-field accessibility rather than a custom editor. |
| Explain panel hierarchy | [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials), [`NSVisualEffectView`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview?changes=__7_5), [AppKit accessibility](https://developer.apple.com/documentation/%61ppkit/accessibility-for-appkit) | Keep the compact borderless panel and standard `NSTextView`/`NSScrollView` content. Add a header/context label, user/answer hierarchy, and clear loading/retry language. Keep the content layer readable and do not render hidden selection text. | No custom Liquid Glass effect, transcript persistence, or selection-content exposure. |

### Feature branch decisions

| Feature branch | Pattern-to-code decision | State/contract mapping |
| --- | --- | --- |
| OCR | Reuse the existing system crop flow. Use shared status/HUD outcome vocabulary after the crop returns; do not build a custom cropper. | Permission, Escape, empty image, no readable text, API/budget/network failure, clipboard success, timeout/cancel; screenshot remains in memory and OCR stays clipboard-only. |
| Refine | Reuse the shared contextual-result and replacement-fallback language. Keep the current safe replacement algorithm and clipboard fallback. | No selection, accessibility/key/budget failure, working, API failure, unchanged replacement, changed-selection fallback, cancel/timeout. |
| Translate | Route through the shared one-field panel with `Translate` context and an example target-language placeholder. Use a concise clipboard-only success outcome. | No selection, input/cancel/focus loss, API/budget/network failure, clipboard success, cancel/timeout; original selection remains untouched. |
| Format | Route through the shared one-field panel with `Format` context and an example instruction placeholder. Reuse replacement/fallback outcomes. | No selection, input/cancel/focus loss, API/budget/network failure, unchanged replacement, changed-selection fallback, cancel/timeout. |
| Finder Path | Keep the local AppleScript path flow and use source-aware shared outcomes for selected items versus the front-window folder. | Finder unavailable, selection, front-window fallback, empty context, Automation denial, script failure, one/multiple path success; no API/budget/Accessibility requirement is added. |
| Explain/chat | Reuse the standard content panel and add hierarchy only around the transcript/composer. Keep selection attachment non-sensitive and transient. | General chat/no selection, hidden selection, empty prompt, loading, reopen/in-flight, answer, retryable failure, focus loss/background completion, one-hour reset. |

### Small AppKit templates for implementation

Use these as patterns, not as a new abstraction layer:

```swift
let surface = NSVisualEffectView(frame: .zero)
surface.material = .hudWindow
surface.blendingMode = .behindWindow
surface.state = .active

let item = NSMenuItem(title: "Translate", action: nil, keyEquivalent: "")
item.isEnabled = false // Reference row; global shortcut remains the execution path.
```

For the content panels, prefer `NSTextField(labelWithString:)`, `NSTextField`, `NSTextView`, `NSScrollView`, and `NSButton` so AppKit supplies normal keyboard and accessibility behavior. Set explicit `accessibilityLabel`/`accessibilityHelp` only on the custom panel/view boundaries and context labels. Use `NSAlert.messageText`, `informativeText`, and standard buttons for first-run disclosure.

### Liquid Glass decision

Apple’s current Liquid Glass API guidance is useful for hierarchy, restraint, grouping, and adaptivity, but the approved implementation does not adopt `glassEffect`, `GlassEffectContainer`, or `NSGlassEffectView`. Those APIs would require a newer platform/SDK path than the project’s `.macOS(.v13)` baseline or introduce availability branches that do not solve an approved problem. The implementation therefore uses compatible AppKit materials and the same design principles.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Shared foundation mapping | Done | Mapped semantic AppKit styles, materials, standard controls, menu, alert, HUD, prompt, and Explain surface patterns | 7 official source links; macOS 13-compatible baseline selected | Map feature branches |
| OCR / Refine / Translate / Format mapping | Done | Mapped all four text/OCR branches to shared outcomes, native input, and existing safety contracts | Four approved feature branches; no hotkey, model, privacy, or replacement contract changes | Map Finder/Explain and verification |
| Finder Path / Explain / verification mapping | Done | Mapped Finder Path, Explain, and final verification surfaces, including explicit no-new-feature decisions | Two remaining feature branches plus shared verification states covered | Unlock Stage 4 shared foundation |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Every approved Stage 4 branch has a selected compatible pattern, code-template note, or explicit rationale to retain the existing native treatment.

Handoff rule:
Unlock Stage 4 shared foundation. Carry source links and compatibility notes into the relevant implementation nodes.
