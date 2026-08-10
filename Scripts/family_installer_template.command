#!/bin/zsh
set -euo pipefail

APP_NAME="AI Shortcuts"
BUNDLE_ID="com.susanawang.aishortcuts"
EXECUTABLE_NAME="AIShortcuts"
AGENT_LABEL="com.susanawang.aishortcuts"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
MACOS_PATH="${APP_PATH}/Contents/MacOS"
AGENT_PATH="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_TARGET="gui/${UID}/${AGENT_LABEL}"
SUPPORT_PATH="${HOME}/Library/Application Support/${BUNDLE_ID}"
BOOTSTRAP_KEY_PATH="${SUPPORT_PATH}/bootstrap-key"
SCRIPT_PATH=${0:A}

MACOS_MAJOR=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')
if (( MACOS_MAJOR < 13 )); then
    print "AI Shortcuts requires macOS 13 Ventura or newer."
    read "?Press Return to close."
    exit 1
fi

APP_MARKER_LINE=$(/usr/bin/grep -n '^__AI_SHORTCUTS_APP_PAYLOAD__$' "${SCRIPT_PATH}" | /usr/bin/cut -d: -f1)
KEY_MARKER_LINE=$(/usr/bin/grep -n '^__AI_SHORTCUTS_KEY_PAYLOAD__$' "${SCRIPT_PATH}" | /usr/bin/cut -d: -f1)
if [[ -z "${APP_MARKER_LINE}" || -z "${KEY_MARKER_LINE}" ]]; then
    print "This installer is incomplete. Ask for a fresh copy."
    read "?Press Return to close."
    exit 1
fi

TEMP_PATH=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-shortcuts-family.XXXXXX")
trap '/bin/rm -rf "${TEMP_PATH}"' EXIT
PAYLOAD_ZIP="${TEMP_PATH}/AI-Shortcuts.zip"
EXTRACT_PATH="${TEMP_PATH}/extracted"
/bin/mkdir -p "${EXTRACT_PATH}"

/usr/bin/sed -n "$((APP_MARKER_LINE + 1)),$((KEY_MARKER_LINE - 1))p" "${SCRIPT_PATH}" \
    | /usr/bin/base64 -D > "${PAYLOAD_ZIP}"
/usr/bin/ditto -x -k "${PAYLOAD_ZIP}" "${EXTRACT_PATH}"
SOURCE_APP="${EXTRACT_PATH}/${APP_NAME}.app"
if [[ ! -x "${SOURCE_APP}/Contents/MacOS/${EXECUTABLE_NAME}" ]]; then
    print "The embedded application could not be verified."
    read "?Press Return to close."
    exit 1
fi

/bin/mkdir -p "${HOME}/Applications" "${HOME}/Library/LaunchAgents" "${SUPPORT_PATH}"
/bin/chmod 700 "${SUPPORT_PATH}"
launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true

EXISTING_PIDS=()
for EXISTING_PID in $(/usr/bin/pgrep -x "${EXECUTABLE_NAME}" 2>/dev/null || true); do
    EXISTING_COMMAND=$(/bin/ps -p "${EXISTING_PID}" -o command= | /usr/bin/sed 's/^[[:space:]]*//')
    if [[ "${EXISTING_COMMAND}" == "${MACOS_PATH}/${EXECUTABLE_NAME}" ]]; then
        EXISTING_PIDS+=("${EXISTING_PID}")
        /bin/kill "${EXISTING_PID}" >/dev/null 2>&1 || true
    fi
done

# AppKit may take a moment to finish termination. Wait before installing so a
# relaunch cannot mistake the outgoing process for a second live instance.
for ATTEMPT in {1..30}; do
    STILL_RUNNING=()
    for EXISTING_PID in "${EXISTING_PIDS[@]}"; do
        if /bin/kill -0 "${EXISTING_PID}" >/dev/null 2>&1; then
            STILL_RUNNING+=("${EXISTING_PID}")
        fi
    done
    EXISTING_PIDS=("${STILL_RUNNING[@]}")
    (( ${#EXISTING_PIDS[@]} == 0 )) && break
    /bin/sleep 0.1
done
for EXISTING_PID in "${EXISTING_PIDS[@]}"; do
    /bin/kill -9 "${EXISTING_PID}" >/dev/null 2>&1 || true
done

if [[ -e "${APP_PATH}" ]]; then
    /bin/rm -rf "${APP_PATH}"
fi
/usr/bin/ditto "${SOURCE_APP}" "${APP_PATH}"
/usr/bin/xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

umask 077
/usr/bin/tail -n "+$((KEY_MARKER_LINE + 1))" "${SCRIPT_PATH}" \
    | /usr/bin/base64 -D > "${BOOTSTRAP_KEY_PATH}"
/bin/chmod 600 "${BOOTSTRAP_KEY_PATH}"

/usr/bin/plutil -create xml1 "${AGENT_PATH}"
/usr/bin/plutil -insert Label -string "${AGENT_LABEL}" "${AGENT_PATH}"
/usr/bin/plutil -insert ProgramArguments -json "[\"${MACOS_PATH}/${EXECUTABLE_NAME}\"]" "${AGENT_PATH}"
/usr/bin/plutil -insert RunAtLoad -bool true "${AGENT_PATH}"
/usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "${AGENT_PATH}"
/usr/bin/plutil -insert ProcessType -string "Interactive" "${AGENT_PATH}"
/usr/bin/plutil -insert LimitLoadToSessionType -string "Aqua" "${AGENT_PATH}"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "${AGENT_PATH}"
/usr/bin/plutil -insert StandardOutPath -string "/dev/null" "${AGENT_PATH}"
/usr/bin/plutil -insert StandardErrorPath -string "/dev/null" "${AGENT_PATH}"
/bin/chmod 600 "${AGENT_PATH}"

/usr/bin/tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null 2>&1 || true
/usr/bin/tccutil reset ScreenCapture "${BUNDLE_ID}" >/dev/null 2>&1 || true
/usr/bin/tccutil reset AppleEvents "${BUNDLE_ID}" >/dev/null 2>&1 || true
/usr/bin/defaults write "${BUNDLE_ID}" permissionsRequested.v1 -bool false

launchctl bootstrap "gui/${UID}" "${AGENT_PATH}"
launchctl kickstart -k "${AGENT_TARGET}"

print ""
print "AI Shortcuts is installed and running."
print "Look for the sparkle in the menu bar, confirm the disclosure, and grant the requested macOS permissions."
print "If macOS blocks this installer after downloading it, right-click it and choose Open once."
read "?Press Return to close."
exit 0

__AI_SHORTCUTS_APP_PAYLOAD__
