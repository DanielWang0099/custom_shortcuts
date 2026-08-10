# Integration, Build, Manual State Matrix, and Visual Verification

Node type: Task
Status: Complete
Parent: `stages/04-implementation/STAGE.md`
Task model basis: `TASK_MODEL.md#task-to-node-trace`
Progress cursor: `MASTER_PROGRESS.md`

## Scope

Owns:
- Final build/check execution, coverage of the original six features plus approved follow-up shortcuts, visual consistency review, and documented limitations/deferred items.

Does not own:
- New fixes outside the approved scope or a separate redesign after implementation.

Parent context:
- Compilation alone is insufficient. The final review must prove the app remains quick, coherent, and safe.

## Execution

Plan:
- Run `swift run AIShortcutsCoreChecks`.
- Run `swift build -c release`.
- Exercise each six-feature branch and its important prerequisite, busy/cancel, success, failure/unsupported, and safety states.
- Review light/dark or available appearance variants, hierarchy, spacing, feedback timing, focus, and accessibility-sensitive treatment.
- Record failures, environment limitations, and any deferred item.

Done checks:
- [x] Existing checks pass or failures have a clear diagnosis and status.
- [x] Release build passes or limitation is recorded.
- [x] Six features have explicit source/state evidence; selection safety and hidden Explain context are checked.
- [x] The final visual/accessibility limitation is recorded with the exact next runtime review condition.
- [x] Status menu, guide, and new shortcut surfaces have source/build evidence; remaining pixel-level owner inspection is explicitly deferred.

Guardrails:
- Do not call the project complete based on build output alone.
- If runtime access is unavailable, state the limitation and separate source/build evidence from visual claims.

## Verification Notes

### Six-feature source/state matrix

| Branch | Prerequisite / launch | Busy, cancel, and failure treatment | Success and safety proof |
| --- | --- | --- | --- |
| OCR | Screen Recording gate and system crop remain in `AppDelegate.runOCR`. | Escape/empty capture, no readable text, budget/API/network, timeout, and cancellation remain non-blocking and use the shared outcome vocabulary. | `OCR copied`; result remains clipboard-only; screenshot data is not persisted. |
| Refine | Accessibility and selection capture gates remain unchanged. | Busy, no selection, API/budget/network, timeout, and cancellation remain explicit. | HUD distinguishes `Refined · replaced` from `Refined · copied`; `replaceIfUnchanged` remains the safety boundary. |
| Translate | Selection capture is followed by the labeled one-field `Translate` panel with `e.g. Japanese, formal`. | Empty input, focus loss, Escape, busy, budget/API/network, timeout, and cancellation retain the existing fast return path. | `Translation copied`; original selection is never replaced. |
| Format | Selection capture is followed by the labeled one-field `Format` panel with `e.g. concise email with bullets`. | Empty input, focus loss, Escape, busy, budget/API/network, timeout, and cancellation retain the shared treatment. | `Formatted · replaced` versus `Formatted · copied`; changed selections remain protected. |
| Finder Path | Finder selection remains local AppleScript and returns the selected file or folder's complete POSIX path. | Empty selection, Automation denial, script failure, and cancellation retain source-aware HUD feedback. | Selected item paths remain clipboard-only; no API, budget, or extra permission path was added. |
| Explain/chat | Selection remains captured with `preserveClipboard: true`; hidden context is represented only by the header/placeholder state. | Loading, retry/error, focus-loss dismissal, in-flight reopen, background completion, and one-hour memory reset remain explicit. | User/Explain transcript hierarchy is visible while selected text is never rendered; transient memory contract remains unchanged. |

### Interactive preview evidence and remaining limitation

The actual `ExplanationPanelController` and `PromptPanelController` were packaged into a temporary preview app and inspected through Computer Use. Explain showed the compact header, `Selection attached · stays hidden`, separate `You`/`Explain` hierarchy, focused composer, and non-sensitive placeholder; Translate showed the labeled title, focused input, and `e.g. Japanese, formal` placeholder. Their accessibility trees exposed the intended labels and keyboard help.

The original status-menu preview could not be captured because the Mac became locked and automatic unlock was unavailable. The Mac was later unlocked and the approved release was installed through `Scripts/install.sh`; the installed `/Users/susanawang/Applications/AI Shortcuts.app` is running under its LaunchAgent. Prompt, Explain, and transcript surfaces have since been inspected, while the menu-bar item itself and the owner-controlled Finder consent action remain for manual inspection.

### Installed visual refinement after owner review

Owner screenshots showed that the first implementation inherited a bright white panel appearance, used an oversized Explain canvas, exposed an oversized blue text-field focus ring, and did not vertically center the composer text. The prompt and Explain surfaces were therefore revised without changing their two-surface interaction model: both now use a stable graphite palette, restrained violet focus/context accents, compact proportions, raised inner composers, centered text geometry, and an optional click target that mirrors Return submission. The installed Translate panel and the actual Explain controller were inspected through Computer Use after the change; both exposed the expected accessibility labels and showed centered placeholder/typed text. The temporary Explain preview entry point was restored to the production `AppDelegate` entry point before the final release rebuild.

### Feedback consistency, Explain turns, and Finder Automation

The remaining HUD states now use the same graphite shell and primary text as the prompt surfaces, with muted sage, violet, or amber icon accents instead of bright red/green text. Explain renders each user prompt in a rounded filled block with a restrained violet contour, leaves a deliberate gap before the answer, and animates to the start of a newly completed answer rather than jumping to its end. Finder access now uses `AEDeterminePermissionToAutomateTarget` with explicit granted/not-determined/denied states, a dedicated readiness-menu row, numeric AppleEvent error handling, and `NSAppleEventsUsageDescription` in the installed bundle. Apple documents that `-1743` represents denied AppleEvent access and that authorization can be preflighted with this API. Actual consent remains an owner action in the macOS prompt or Privacy & Security → Automation.

A follow-up owner screenshot exposed a final Explain typography defect: the user card entered the overlay-scroller gutter, the assistant label sat too close to the card, and the answer sat too far below its label. The card now uses a 96% content width with reduced vertical padding, while the assistant label and answer share one paragraph with a controlled pre-gap and line spacing.

A later installed-app check exposed two regressions: the selection-only Finder AppleScript was missing its closing `end if`, and the Explain composer could retain a stale scroll offset after its text was cleared or restored. The Finder branch is structurally closed again and continues to copy the full selected-item path. Explain now resets the editor origin after programmatic text changes, vertically centers its one-line state, keeps the complete current prompt visible while waiting, and opens completed turns at the beginning of the latest answer instead of the transcript bottom. Display-only blank-line runs are also collapsed so model paragraph breaks do not stack with AppKit paragraph spacing.

### Follow-up multimodal and local-shortcut pass

Explain now accepts up to four pasted images directly in the composer, renders removable thumbnails, sends them as Responses API `input_image` content with the existing key, and discards image bytes from conversation history after the request. Calculate now uses a generic final-answer-only contract that suppresses source restatement, reasoning, assumptions, and visibly truncated labels; Calculate and Explain use low reasoning while the immediate OCR/text actions remain non-reasoning. Finder Path moved from ⌃⌥⌘P to ⌃⌥⌘\.

⌃⌥⌘L now opens a two-option keyboard selector. Keyboard Lock suppresses all keystrokes except the restoring chord; Shortcut Lock suppresses modifier shortcuts while preserving ordinary typing. The active Core Graphics event tap and indicator are process-owned, so normal termination and crashes remove the filter automatically. Cross-application window pinning on ⌃⌥⌘P is deferred: public AppKit window levels apply only to this app's windows, while the public Accessibility surface exposes one-shot Raise but no persistent external-window level. Private WindowServer calls and repeated Raise polling were rejected as unreliable and focus-disruptive.

A Finder runtime check then exposed that Finder can return a selected item while evaluating `count of selection` as zero. The AppleScript now snapshots `selection` into `selectedItems` before counting and iterating it; the reproduced selected PDF resolved to its complete `/Users/susanawang/Downloads/...pdf` path.

### Sequential Clipboard follow-up

⌃⌥⌘C now starts a fresh process-local clipboard queue in collection mode. Physical ⌘C operations continue normally and clone complete stable pasteboard representations into a bounded 50-item/100 MB FIFO; AI Shortcuts' synthetic copy/paste events are excluded by source process identifier. Pressing ⌃⌥⌘C again switches to paste mode, where each physical ⌘V places and consumes the next item before the target app handles Paste. Emptying the queue removes the event tap and returns to ordinary clipboard behavior with the last pasted item still available. A third ⌃⌥⌘C while pasting cancels the remaining queue. App termination or a crash removes the process-owned event tap and in-memory queue.

### Insert and Shortcut Guide follow-up

⌃⌥⌘I now opens one adaptive Insert panel. Lookup resolves exact and uniquely contained keys locally, while ambiguous wording uses a constrained low-reasoning request over key labels only; saved values never enter the API request and the model can select only an existing candidate index. `/new`, `/modify`, and `/delete` transform the same panel into focused creation, searchable inline editing, and searchable deletion states. Duplicate normalized keys and empty entries fail closed. Entries persist in an owner-only Application Support JSON file. Successful insertion reactivates the app that owned focus, pastes the local value, and restores the prior clipboard; failure copies the value with explicit HUD feedback.

The menu-bar shortcut inventory now includes **Shortcut Guide…** with an info symbol. It opens one scrollable graphite reference window covering every registered shortcut, shortcut chord, purpose, output destination, and permission or network requirement. The guide uses the existing shared visual tokens and remains readable while switching apps. Computer Use could inspect ordinary app windows but could not directly address the accessory-only menu-bar process, so final pixel-level inspection of the installed menu item, guide, and Insert mode transitions remains an explicit owner review rather than an unsupported visual claim.

### Insert editability regression record

Owner screenshots exposed a repeatable lifecycle regression: after an AI-assisted lookup set the warm Insert controller to resolving, dismiss/reopen cleared only the controller Boolean while leaving the reused `NSTextField` non-editable. Replacing the field cell and rebuilding could therefore appear fixed once but did not repair the stale resolving state. `show` and `dismiss` now both pass through `setResolving(false)`, which restores editability, button state, and header copy as one invariant; a debug assertion checks that the lookup field is editable every time the panel opens. This root cause and invariant supersede the earlier field-cell-only diagnosis.

## Tracking - Only One Line Active Or Modified

Only one tracking line may be active or modified at once. Do not work multiple lines in parallel.

| Item | Status | Output / reason | Evidence / count | Next |
| --- | --- | --- | --- | --- |
| Build and core checks | Done | Release build and all existing core behavior suites pass; the project installer rebuilt, packaged, signed, and relaunched the installed app | `swift build -c release`; `swift run AIShortcutsCoreChecks`; `./Scripts/install.sh`; nine PASS lines; signed process `75366` observed running | Review feature matrix |
| Six-feature manual matrix | Done | Six branches have explicit source/state coverage; the installed running instance prevented interactive control, so the limitation is recorded separately | 6/6 source/state rows in Verification Notes; no runtime visual claim | Record final visual/accessibility limitation |
| Visual/accessibility pass | Done | Shared surfaces, Insert modes, and Shortcut Guide use the graphite UI system; unsupported direct control of the accessory menu process is documented as owner-level pixel inspection | Owner screenshot-driven corrections; source review; release/core checks; installed app running; production entry point preserved | Owner may report any final pixel-level defect from manual use |

## Child Nodes

No child nodes.

## Completion And Handoff

Completion rule:
All three verification rows have command/review evidence, every required child is complete, and remaining limitations or deferred work are explicit.

Handoff rule:
Update `MASTER_PROGRESS.md`, close Stage 4, and apply the project completion rule. No further implementation work is implied by this node.
