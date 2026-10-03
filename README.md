# AI Shortcuts for macOS

Native macOS keyboard shortcuts powered by your own AI model.

## Shortcuts

| Shortcut | Description |
| --- | --- |
| ⌃ ⌥ ⌘ 4 | OCR screen selection |
| ⌃ ⌥ ⌘ = | Calculate screen selection |
| ⌃ ⌥ ⌘ R | Refine selected text |
| ⌃ ⌥ ⌘ T | Translate selected text |
| ⌃ ⌥ ⌘ F | Reformat selected text |
| ⌃ ⌥ ⌘ \\ | Copy Finder POSIX path |
| ⌃ ⌥ ⌘ E | Explain selection or image |
| ⌃ ⌥ ⌘ L | Lock input |
| ⌃ ⌥ ⌘ C | Sequential clipboard (FIFO) |
| ⌃ ⌥ ⌘ I | Quick insert snippet |
| ⌃ ⌥ ⌘ / | Start or resume ChatGPT voice in Chrome |

### ChatGPT Voice

Press **⌃⌥⌘/** to open a new ChatGPT tab in your normal Chrome profile and start voice. Chrome launches if it is closed. The shortcut activates the named English or Chinese Accessibility voice button rather than using screen coordinates.

The app remembers only the tab created by this shortcut. It resumes that chat within **30 minutes of observed voice inactivity**. If the call is still active, the shortcut brings its tab forward and leaves the call and its mute state unchanged, even after 30 minutes. After the idle window expires, it opens a fresh chat and leaves the previous tab intact. It also starts fresh if the remembered tab is closed, navigates away from ChatGPT, or Chrome restarts. Tracking is held in memory and clears when AI Shortcuts restarts or the shortcut is disabled.

If ChatGPT ends a call and the voice button disappears, the shortcut reloads the same chat once to recover the button before restarting voice. It only attempts this recovery when no active-call, connecting, or recording controls are detected.

This shortcut requires **Accessibility**, permission for **AI Shortcuts to control Google Chrome** under macOS **Privacy & Security → Automation**, and a signed-in ChatGPT session with browser microphone access. It works without an API key, configured AI provider, or Screen Recording permission. Finish any ChatGPT sign-in, voice setup, or microphone permission prompts in Chrome, then retry the shortcut. A failed voice start retains its new tab for an explicit retry.

The shortcut is enabled by default. Toggle **ChatGPT Voice** in the menu bar app to enable or disable it.

## Install

```sh
./Scripts/install.sh
```

The installer builds the release binary, registers the background LaunchAgent, and launches the app into your top menu bar.

## Setup

1. **Permissions**: Grant **Accessibility** and **Screen Recording** permissions when prompted.
2. **Model Settings**: Click the menu bar icon and select **Model Settings…** to configure:
   - **Request Style**: OpenAI-compatible or Anthropic
   - **Endpoint & Model**: Custom URL and model ID (e.g. OpenAI, Anthropic, or local endpoints like Ollama / vLLM)
   - **API Key**: Saved securely in your macOS login Keychain

## Development

I have no idea how to develop, use AI to code lol.

## Uninstall

To remove the installed app, LaunchAgent, Keychain entries, and preferences:

```sh
./Scripts/uninstall.sh
```
