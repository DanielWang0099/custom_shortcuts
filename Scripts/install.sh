#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="AI Shortcuts"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
EXECUTABLE_NAME="AIShortcuts"
BUNDLE_ID="com.susanawang.aishortcuts"
KEYCHAIN_SERVICE="com.susanawang.aishortcuts.openai"
KEYCHAIN_ACCOUNT="default"
AGENT_LABEL="com.susanawang.aishortcuts"
AGENT_PATH="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_TARGET="gui/${UID}/${AGENT_LABEL}"
SUPPORT_PATH="${HOME}/Library/Application Support/${BUNDLE_ID}"
BOOTSTRAP_KEY_PATH="${SUPPORT_PATH}/bootstrap-key"

if (( $# > 1 )); then
  print "Usage: ./Scripts/install.sh [path-to-env-file]"
  exit 64
fi
if [[ "${1:-}" == "--help" ]]; then
  print "Usage: ./Scripts/install.sh [path-to-env-file]"
  print ""
  print "An optional env file supplies OPENAI_API_KEY for this install only."
  print "Without one, the app asks for your key on first launch."
  exit 0
fi

KEY_SOURCE_PATH="${1:-${AI_SHORTCUTS_KEY_FILE:-${PROJECT_DIR}/.env.local}}"

cd "${PROJECT_DIR}"

API_KEY="${OPENAI_API_KEY:-}"
if [[ -z "${API_KEY}" && -f "${KEY_SOURCE_PATH}" ]]; then
  API_KEY=$(/usr/bin/awk '
    /^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((substr(value,1,1)=="\"" && substr(value,length(value),1)=="\"") ||
          (substr(value,1,1)=="\047" && substr(value,length(value),1)=="\047")) {
        value=substr(value,2,length(value)-2)
      }
      print value
      exit
    }
  ' "${KEY_SOURCE_PATH}")
fi
if [[ ${#API_KEY} -le 20 ]]; then
  API_KEY=""
fi
unset OPENAI_API_KEY

swift run AIShortcutsCoreChecks
swift run AIShortcutsRenderingChecks
swift build -c release --product AIShortcuts
BIN_PATH=$(swift build -c release --show-bin-path)
RENDERING_RESOURCE_BUNDLE="${BIN_PATH}/AIShortcuts_AIShortcutsRendering.bundle"
if [[ ! -d "${RENDERING_RESOURCE_BUNDLE}" ]]; then
  print "The bundled transcript renderer resources were not built."
  exit 1
fi

mkdir -p "${HOME}/Applications" "${HOME}/Library/LaunchAgents"
launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true

# A copy started manually with `open` is not owned by the LaunchAgent and can
# survive bootout. Stop that exact installed executable so the newly
# bootstrapped agent always owns the single running process.
EXISTING_PIDS=()
for EXISTING_PID in $(pgrep -x "${EXECUTABLE_NAME}" 2>/dev/null || true); do
  EXISTING_COMMAND=$(ps -p "${EXISTING_PID}" -o command= | sed 's/^[[:space:]]*//')
  if [[ "${EXISTING_COMMAND}" == "${MACOS_PATH}/${EXECUTABLE_NAME}" ]]; then
    EXISTING_PIDS+=("${EXISTING_PID}")
    kill "${EXISTING_PID}" >/dev/null 2>&1 || true
  fi
done

for ATTEMPT in {1..30}; do
  STILL_RUNNING=()
  for EXISTING_PID in "${EXISTING_PIDS[@]}"; do
    if kill -0 "${EXISTING_PID}" >/dev/null 2>&1; then
      STILL_RUNNING+=("${EXISTING_PID}")
    fi
  done
  EXISTING_PIDS=("${STILL_RUNNING[@]}")
  (( ${#EXISTING_PIDS[@]} == 0 )) && break
  sleep 0.1
done
for EXISTING_PID in "${EXISTING_PIDS[@]}"; do
  kill -9 "${EXISTING_PID}" >/dev/null 2>&1 || true
done

if [[ -e "${APP_PATH}" ]]; then
  rm -rf "${APP_PATH}"
fi
mkdir -p "${MACOS_PATH}" "${CONTENTS_PATH}/Resources"
cp "${BIN_PATH}/${EXECUTABLE_NAME}" "${MACOS_PATH}/${EXECUTABLE_NAME}"
cp -R "${RENDERING_RESOURCE_BUNDLE}" "${CONTENTS_PATH}/Resources/"
chmod 755 "${MACOS_PATH}/${EXECUTABLE_NAME}"

INFO_PLIST="${CONTENTS_PATH}/Info.plist"
plutil -create xml1 "${INFO_PLIST}"
plutil -insert CFBundleDevelopmentRegion -string "en" "${INFO_PLIST}"
plutil -insert CFBundleDisplayName -string "${APP_NAME}" "${INFO_PLIST}"
plutil -insert CFBundleExecutable -string "${EXECUTABLE_NAME}" "${INFO_PLIST}"
plutil -insert CFBundleIdentifier -string "${BUNDLE_ID}" "${INFO_PLIST}"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${INFO_PLIST}"
plutil -insert CFBundleName -string "${APP_NAME}" "${INFO_PLIST}"
plutil -insert CFBundlePackageType -string "APPL" "${INFO_PLIST}"
plutil -insert CFBundleShortVersionString -string "1.0.0" "${INFO_PLIST}"
plutil -insert CFBundleVersion -string "1" "${INFO_PLIST}"
plutil -insert LSMinimumSystemVersion -string "13.0" "${INFO_PLIST}"
plutil -insert LSUIElement -bool true "${INFO_PLIST}"
plutil -insert NSHighResolutionCapable -bool true "${INFO_PLIST}"
plutil -insert NSPrincipalClass -string "NSApplication" "${INFO_PLIST}"
plutil -insert NSAppleEventsUsageDescription -string "AI Shortcuts asks Finder for the selected file or folder so it can copy the complete POSIX path." "${INFO_PLIST}"
plutil -insert NSScreenCaptureUsageDescription -string "AI Shortcuts captures only the screen region you select for AI OCR." "${INFO_PLIST}"

codesign --force --deep --sign - --identifier "${BUNDLE_ID}" "${APP_PATH}"
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
  -f "${APP_PATH}"

plutil -create xml1 "${AGENT_PATH}"
plutil -insert Label -string "${AGENT_LABEL}" "${AGENT_PATH}"
plutil -insert ProgramArguments -json "[\"${MACOS_PATH}/${EXECUTABLE_NAME}\"]" "${AGENT_PATH}"
plutil -insert RunAtLoad -bool true "${AGENT_PATH}"
plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "${AGENT_PATH}"
plutil -insert ProcessType -string "Interactive" "${AGENT_PATH}"
plutil -insert LimitLoadToSessionType -string "Aqua" "${AGENT_PATH}"
plutil -insert ThrottleInterval -integer 10 "${AGENT_PATH}"
plutil -insert StandardOutPath -string "/dev/null" "${AGENT_PATH}"
plutil -insert StandardErrorPath -string "/dev/null" "${AGENT_PATH}"
chmod 600 "${AGENT_PATH}"

# Local ad-hoc signatures change when the executable is rebuilt. Remove only
# this app's old permission decisions before launching the new signature so
# macOS presents fresh, non-stale authorization entries.
tccutil reset Accessibility "${BUNDLE_ID}"
tccutil reset ScreenCapture "${BUNDLE_ID}"
tccutil reset AppleEvents "${BUNDLE_ID}"
defaults write "${BUNDLE_ID}" permissionsRequested.v1 -bool false

# Rebuilding changes the ad-hoc signature, so an existing generic-password
# item can retain an ACL for the previous executable. Remove only this app's
# item; the newly launched app imports the optional bootstrap key or asks for
# one, then creates a fresh ACL for its current signature.
/usr/bin/security delete-generic-password \
  -s "${KEYCHAIN_SERVICE}" \
  -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1 || true

if [[ -n "${API_KEY}" ]]; then
  /bin/mkdir -p "${SUPPORT_PATH}"
  /bin/chmod 700 "${SUPPORT_PATH}"
  umask 077
  print -rn -- "${API_KEY}" > "${BOOTSTRAP_KEY_PATH}"
  /bin/chmod 600 "${BOOTSTRAP_KEY_PATH}"
else
  /bin/rm -f "${BOOTSTRAP_KEY_PATH}" >/dev/null 2>&1 || true
fi
unset API_KEY

launchctl bootstrap "gui/${UID}" "${AGENT_PATH}"
launchctl kickstart -k "${AGENT_TARGET}"

echo "Installed ${APP_PATH}"
echo "AI Shortcuts is running and will launch automatically at login."
echo "If no key was supplied, the app will ask for your OpenAI API key on first launch."
