# AI Shortcuts for macOS

A lightweight native menu-bar utility that sends deliberately selected content to OpenAI GPT-5.4 models. It has no Dock icon, performs no idle polling, and launches automatically at login.

## Shortcuts

| Shortcut | Action | Result |
| --- | --- | --- |
| Control–Option–Command–4 | Select a cropped screenshot and run AI OCR | OCR text is copied |
| Control–Option–Command–= | Select a cropped screenshot and calculate the most useful operation | Optional instruction is shown; the answer popup stays until you move the cursor away from it and is copied |
| Control–Option–Command–R | Refine selected text without changing its meaning | Result is copied and replaces an unchanged selection |
| Control–Option–Command–T | Translate selected text using the instruction typed into the blank field | Result is copied only |
| Control–Option–Command–F | Reformat selected text using the instruction typed into the blank field | Result is copied and replaces an unchanged selection |
| Control–Option–Command–\ | Copy the full POSIX path of each selected Finder file or folder | Full selected-item path is copied only |
| Control–Option–Command–E | Open a compact AI chat; selected text is attached invisibly and images can be pasted into the composer | Prompt, image thumbnails, and brief answers stay in one borderless panel |
| Control–Option–Command–L | Choose Keyboard Lock or Shortcut Lock; press the same shortcut again to restore input | The lock exists only while AI Shortcuts is running |
| Control–Option–Command–C | Start a fresh sequential clipboard queue; press again to switch from collecting `⌘C` copies to FIFO `⌘V` pasting | The queue is memory-only and normal clipboard behavior returns when empty |
| Control–Option–Command–I | Insert a saved value by key; type `/new`, `/modify`, or `/delete` to manage the local library | The value is pasted into the original app and the previous clipboard is restored |

Calculate opens its instruction field after the crop. Press Return with the field empty to let the model choose the most useful operation from the visible app context, or type a custom instruction before pressing Return.

If a selection or focus changes before Refine or Format completes, the app does not paste. It leaves the result on the clipboard instead.

## Install

The app expects the existing key source at:

`~/Documents/GitHub/japanese-practice/vocabulary-flashcard-practice/.env.local`

The file must contain `OPENAI_API_KEY`. The installer and application never print the value. On first launch, the app imports the exact value into the macOS login Keychain.

```sh
./Scripts/install.sh
```

On first launch:

1. Grant Accessibility and Screen Recording permissions. Install/update resets this app's stale entries for both permissions and its rebuilt-signature Keychain item before launching the new app. macOS may require restarting the app after Screen Recording is granted.
2. After the macOS permission flow and any required restart are complete, confirm in the OpenAI dashboard that the key's project is enrolled for complimentary daily tokens and input/output sharing is enabled.
3. Read the disclosure and choose **I Confirm**. The app then imports the key into the macOS login Keychain.

If a permission is missing later, using an affected shortcut opens the correct System Settings pane automatically. The menu also provides **Restart AI Shortcuts**.

`Scripts/build_family_installer.sh` creates a private, single-file family installer in `dist/`. That generated file embeds the configured shared API key and is intentionally ignored by Git; distribute it only through a private channel.

The menu-bar sparkle provides permission status, API key status, the local budget guard, data-sharing settings, key reload, restart, and a scrollable **Shortcut Guide…** explaining every available shortcut.

## Complimentary-token guard and privacy

Every AI shortcut uses the pinned full `gpt-5.4-2026-03-05` snapshot with a shared 1,000,000-token local UTC-day guard. Immediate OCR, Refine, Translate, and Format requests keep reasoning at `none`; Explain uses `low`, and Calculate uses `high` with a strict JSON answer schema so the popup and clipboard receive only the final answer, never model reasoning. Explain opens only from Control–Option–Command–E, keeps its composer and answers in one opaque, high-contrast borderless panel, closes when it loses focus, and continues an in-flight answer in the background. Its placeholder changes when selected text or pasted images are attached; hidden selected text is never rendered, while pasted images appear as removable thumbnails before submission. Explain keeps up to six recent exchanges in memory and starts a fresh chat after one hour of inactivity; image bytes are not retained in conversation history. The model matches the complimentary full-model pool shown for this account. There is no fallback model and no local OCR substitution.

Sequential Clipboard is entirely local. Each activation starts an empty in-memory queue, normal `⌘C` appends complete pasteboard items, the second Control–Option–Command–C switches to paste mode, and each normal `⌘V` consumes the next item. The final pasted item remains on the regular macOS clipboard after the queue empties. Quitting or crashing AI Shortcuts drops the temporary queue and event monitor automatically.

Insert stores key/value entries in `~/Library/Application Support/com.susanawang.aishortcuts/insert-library.json` with owner-only file permissions. Exact and uniquely contained key matches are resolved locally. For an ambiguous or approximate request, only the saved key labels—not their values—are sent to OpenAI, which must return the index of one existing entry. Insert then returns to the app that was active when the panel opened, pastes the locally retrieved value, and restores the previous clipboard. `/new`, `/modify`, and `/delete` transform the same panel into focused management views.

Insert also includes two non-editable entries marked **Dynamic**: Date (`YYYY-MM-DD`) and Time (`HH:mm:ss`). Their values are generated when Insert opens, not saved to disk. The names `date` and `time` are reserved so a custom entry cannot replace a built-in.

The utility keeps its small native chat controller warm for immediate display, but bounds conversation data to 48 KB. It has no polling or repeating timers and uses approximately 0% CPU while idle. Network sessions are refreshed after idle gaps to avoid stale VPN connections, and a single interrupted connection is retried once without changing models or endpoints.

This local guard cannot see token use by other applications or verify organization eligibility. A normal project key cannot query organization-wide usage. OpenAI can bill requests when complimentary eligibility or quota is unavailable, so the guard reduces risk but cannot guarantee zero charges.

Selected text and cropped screenshots are shared with OpenAI when a shortcut is used. Do not use the shortcuts with sensitive, confidential, or proprietary content. Screenshots remain in memory and are never written to disk by this app. Prompts, responses, screenshots, selected text, and credentials are not logged.

## Development

```sh
swift run AIShortcutsCoreChecks
swift build -c release
```

The project uses only Swift and macOS system frameworks. Full Xcode is not required.

To remove the installed app, LaunchAgent, imported Keychain item, and preferences:

```sh
./Scripts/uninstall.sh
```
