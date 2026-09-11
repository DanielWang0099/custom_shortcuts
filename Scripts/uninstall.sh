#!/bin/zsh
set -euo pipefail

APP_PATH="${HOME}/Applications/AI Shortcuts.app"
AGENT_LABEL="com.susanawang.aishortcuts"
AGENT_PATH="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
LOCK_PATH="${HOME}/Library/Application Support/AI Shortcuts/instance.lock"

launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true

if [[ -f "${AGENT_PATH}" ]]; then
  rm -f "${AGENT_PATH}"
fi
if [[ -d "${APP_PATH}" ]]; then
  rm -rf "${APP_PATH}"
fi
if [[ -f "${LOCK_PATH}" ]]; then
  rm -f "${LOCK_PATH}"
fi
rmdir "${HOME}/Library/Application Support/AI Shortcuts" >/dev/null 2>&1 || true

security delete-generic-password \
  -s "com.susanawang.aishortcuts.openai" \
  -a "default" >/dev/null 2>&1 || true
security delete-generic-password \
  -s "com.susanawang.aishortcuts.anthropic" \
  -a "default" >/dev/null 2>&1 || true
defaults delete "com.susanawang.aishortcuts" >/dev/null 2>&1 || true

echo "Removed AI Shortcuts, its LaunchAgent, preferences, and imported Keychain item."
