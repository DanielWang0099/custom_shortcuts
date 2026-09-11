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

## Install

```sh
./Scripts/install.sh
```

The installer builds the release binary, registers the background LaunchAgent, and launches the app into your top menu bar.

## Performance behavior

AI Shortcuts keeps only its event-driven Carbon hotkeys and flags-only chord monitor resident while idle. Pressing the shared
`Control + Option + Command` chord starts a short latency-critical wake window and preconnects to the configured
provider with an unauthenticated `HEAD` request (no prompt, API key, or model invocation); pressing an action key
prepares only that shortcut's UI and local dependencies. After 30 seconds without activity, unused panels, WebKit
state, renderers, and allocator pages are trimmed; after 90 seconds, the warm network session is released too. Model
choice, reasoning effort, image detail, and output limits are unchanged by this lifecycle.

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
