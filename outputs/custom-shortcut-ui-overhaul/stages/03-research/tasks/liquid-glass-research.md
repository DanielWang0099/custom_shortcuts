# Apple Liquid Glass and Native macOS Pattern Research

Node type: Task
Status: Complete
Parent: `stages/03-research/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Current official Apple guidance, APIs, examples, and compatibility constraints for Liquid Glass and relevant macOS-native UI patterns.

Does not own:
- Choosing the final redesign, implementing code, or relying on third-party styling examples as authority.

Parent context:
- The project targets macOS 13 and is currently AppKit-based; every source must be checked against that reality.

## Execution

Plan:
- Browse official Apple developer and design sources only for patterns used by the approved plan.
- Cover relevant materials/glass, menus, panels, controls, typography, symbols, focus, accessibility, and transient feedback.
- Record URL, title, access date, API/platform constraint, and the practical takeaway.
- Mark newer-only or unsupported patterns as deferred instead of forcing them into the app.

Done checks:
- [x] Each research row has an official URL, access date, and compatibility note.
- [x] Only patterns relevant to approved branches are retained.
- [x] Research does not claim support for APIs outside the deployment target.

Guardrails:
- Official Apple sources are required for platform claims.
- Keep the output short and actionable; do not create a broad design-literature review.

## Research Findings

Access date for all sources below: 2026-08-10.

| Official source | Platform / API note | Practical takeaway for this app | Decision |
| --- | --- | --- | --- |
| [Liquid Glass technology overview](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass) | Current Apple design guidance for the latest platform design system. | System controls and navigation should carry the visual treatment; hierarchy, restraint, standard iconography, and judicious color matter more than decorative effects. | Adopt the principles. Keep the menu and transient controls quiet and legible. |
| [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass?changes=la__9) | Standard SwiftUI, UIKit, and AppKit components receive the current platform treatment when built with the latest SDK. Custom APIs include SwiftUI `glassEffect`, UIKit `UIGlassEffect`, and AppKit `NSGlassEffectView`. | Prefer standard controls and remove unnecessary custom backgrounds. Test reduced transparency, motion, contrast, and other accessibility settings. | Do not add a framework migration or custom glass API in this pass. Use the compatible AppKit baseline and apply the restraint/hierarchy guidance. |
| [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) | SwiftUI-specific `glassEffect` and `GlassEffectContainer` patterns. | Custom glass is for selected functional surfaces, with a shape, restrained tint, and deliberate grouping. | Deferred: the app is AppKit-based and targets macOS 13; this is not needed to solve the approved UI problems. |
| [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials) | Liquid Glass is a functional layer for controls/navigation; standard materials remain appropriate for content. | Do not turn the transcript, prompt content, or status information into a decorative glass canvas. Use material by intended use, not by color preference, and use glass sparingly. | Keep content surfaces opaque/semantic and reserve translucency for the prompt/HUD-style functional surfaces. |
| [`NSVisualEffectView`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview?changes=__7_5) and [`material`](https://developer.apple.com/documentation/%61ppkit/nsvisualeffectview/material-swift.property) | AppKit-native material and blending controls; compatible with the existing AppKit architecture and macOS 13 baseline. | A surface can use a semantic material, an explicit blending mode, and an active state without introducing another UI framework. | Adopt for shared prompt/HUD surface consistency; keep `windowBackgroundColor`/semantic content backgrounds for readable content. |
| [`NSStatusItem`](https://developer.apple.com/documentation/%61ppkit/nsstatusitem?changes=_4), [`NSStatusBar`](https://developer.apple.com/documentation/%61ppkit/nsstatusbar?changes=_5), and [Menus HIG](https://developer.apple.com/design/human-interface-guidelines/menus) | Native menu-bar item and menu patterns; status items should be used sparingly because menu-bar space is limited. | The menu should expose commands and keyboard shortcuts with standard `NSMenu`/`NSMenuItem` structure, while keeping status/readiness information compact. | Adopt a labeled shortcut inventory and a concise readiness section; do not replace the menu with a custom popover. |
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | macOS-specific density, menu-bar, and keyboard-shortcut guidance. | A menu-bar utility should make commands discoverable while preserving the speed of global shortcuts and comfortable information density. | Adopt the approved discoverability pass without changing the hotkey flow. |
| [Accessibility for AppKit](https://developer.apple.com/documentation/%61ppkit/accessibility-for-appkit) | Standard AppKit controls/views provide built-in accessibility; custom views need explicit role/label treatment. | Standard controls reduce accessibility work; custom panels and status surfaces still need meaningful labels and state descriptions. | Add labels to custom panels and preserve standard text fields, menus, buttons, and scroll views. |
| [`NSAlert`](https://developer.apple.com/documentation/%61ppkit/nsalert) | AppKit-native modal/sheet pattern with message, informative text, buttons, and optional accessory view. | First-run permission and privacy messaging should use a short, structured native alert rather than a custom onboarding system. | Keep `NSAlert`, shorten and structure its copy, and preserve the explicit confirmation gate. |
| [Build an AppKit app with the new design (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/310/) | Official AppKit guidance for the latest design refresh and SDK. | The current SDK can supply system-level design changes through standard AppKit components; custom treatment should be limited to what the product needs. | Use as supporting guidance, not as a reason to raise the deployment target. |

### Compatibility decision

`Package.swift` declares `.macOS(.v13)` and the app is entirely AppKit-based. Apple’s Liquid Glass-specific APIs and the latest design refresh are documented for the current platform/SDK generation, so using them unconditionally would either raise the deployment requirement or require availability branches that add complexity without improving the approved flow. This is an explicit compatibility inference from the project target and Apple’s current API guidance.

The implementation baseline is therefore: standard AppKit controls; `NSVisualEffectView` with existing semantic materials for functional transient surfaces; semantic AppKit colors and system fonts; standard `NSMenu`, `NSMenuItem`, `NSAlert`, `NSTextField`, `NSTextView`, and `NSScrollView`; and explicit accessibility labels on custom surfaces. No SwiftUI migration, `glassEffect`, or `NSGlassEffectView` is approved for this pass. The visual goal is to apply Apple’s hierarchy, layering, restraint, and adaptivity principles while preserving macOS 13 support and the quick shortcut path.

### Reusable AppKit surface template

The compatible surface pattern is intentionally small and matches the existing codebase:

```swift
let surface = NSVisualEffectView(frame: .zero)
surface.material = .hudWindow
surface.blendingMode = .behindWindow
surface.state = .active
```

Use this only for a functional floating surface. Content views should use semantic text colors and a standard content background; do not stack multiple translucent layers or apply a custom glass effect to every control.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Liquid Glass/material guidance | Done | Recorded official Liquid Glass, HIG Materials, and `NSVisualEffectView` guidance with macOS 13 compatibility decision | 5 official URLs; access date 2026-08-10; newer-only APIs explicitly deferred | Research menus/panels |
| Menus, panels, controls, feedback | Done | Recorded native status-item/menu, macOS menu-bar, material-surface, and alert patterns | 6 official URLs; status-menu discoverability and concise native alert selected | Research accessibility |
| Typography, symbols, focus, accessibility | Done | Recorded system-component, hierarchy, semantic-color, and AppKit accessibility guidance | Official HIG/AppKit sources; standard controls retained and custom surfaces labeled | Close research node |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
Every research row has official-source evidence and a compatibility result, including explicit deferrals for anything unavailable or unnecessary.

Handoff rule:
Pass the source record to `pattern-mapping.md`; do not make code changes from this node.
