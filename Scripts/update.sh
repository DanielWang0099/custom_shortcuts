#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="AI Shortcuts"
EXECUTABLE_NAME="AIShortcuts"
BUNDLE_ID="com.susanawang.aishortcuts"
APP_PATH="${HOME}/Applications/${APP_NAME}.app"
APP_PARENT="${APP_PATH:h}"
INSTALLED_CONTENTS="${APP_PATH}/Contents"
INSTALLED_INFO_PLIST="${INSTALLED_CONTENTS}/Info.plist"
INSTALLED_EXECUTABLE="${INSTALLED_CONTENTS}/MacOS/${EXECUTABLE_NAME}"
AGENT_LABEL="${BUNDLE_ID}"
AGENT_PATH="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
AGENT_TARGET="gui/${UID}/${AGENT_LABEL}"
RENDERING_BUNDLE_NAME="AIShortcuts_AIShortcutsRendering.bundle"
ICON_PATH="${PROJECT_DIR}/Resources/AIShortcutsLogo.icns"

RESET_PERMISSIONS=false
SIGNING_IDENTITY_OVERRIDE=""
STAGING_ROOT=""
STAGED_APP=""
BACKUP_APP=""
UPDATE_STARTED=false
UPDATE_COMPLETED=false
ROLLBACK_ATTEMPTED=false
BACKUP_MOVE_STARTED=false

usage() {
  print "Usage: ./Scripts/update.sh [--reset-permissions] [--sign-identity IDENTITY]"
  print ""
  print "Builds and verifies the current checkout, then updates the installed app."
  print "Keeps a backup and preserves the LaunchAgent plist, preferences, and Keychain entries."
  print "Permissions are not reset by default; macOS may ask again if the signature changes."
  print ""
  print "  --reset-permissions       Explicitly reset this app's macOS permission decisions."
  print "  --sign-identity IDENTITY  Use an explicit codesigning identity."
  print "  --help                    Show this help."
}

while (( $# > 0 )); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --reset-permissions)
      RESET_PERMISSIONS=true
      shift
      ;;
    --sign-identity)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        print -u2 "Missing value for --sign-identity."
        usage >&2
        exit 64
      fi
      SIGNING_IDENTITY_OVERRIDE="$2"
      shift 2
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 64
      ;;
  esac
done

cd "${PROJECT_DIR}"

if [[ ! -d "${APP_PATH}" || ! -x "${INSTALLED_EXECUTABLE}" ]]; then
  print -u2 "No installed ${APP_NAME} app was found at ${APP_PATH}."
  print -u2 "Run ./Scripts/install.sh first."
  exit 1
fi
if [[ ! -f "${AGENT_PATH}" ]]; then
  print -u2 "The ${APP_NAME} LaunchAgent is missing at ${AGENT_PATH}."
  print -u2 "Run ./Scripts/install.sh first."
  exit 1
fi
if [[ ! -f "${INSTALLED_INFO_PLIST}" ]]; then
  print -u2 "The installed app has no Info.plist."
  exit 1
fi

INSTALLED_BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${INSTALLED_INFO_PLIST}")
if [[ "${INSTALLED_BUNDLE_ID}" != "${BUNDLE_ID}" ]]; then
  print -u2 "The installed app has bundle identifier ${INSTALLED_BUNDLE_ID}; expected ${BUNDLE_ID}."
  exit 1
fi
AGENT_PROGRAM=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "${AGENT_PATH}")
if [[ "${AGENT_PROGRAM}" != "${INSTALLED_EXECUTABLE}" ]]; then
  print -u2 "The LaunchAgent does not point to the installed executable."
  exit 1
fi

# Preserve the installed signing identity. Ad-hoc signatures intentionally
# use "-" again; their designated requirement changes with each rebuild, so
# this script never attempts to preserve an old cdhash requirement.
/usr/bin/codesign --verify --deep --strict "${APP_PATH}"
SIGNATURE_DETAILS=$(/usr/bin/codesign --display --verbose=4 "${APP_PATH}" 2>&1)
if [[ -n "${SIGNING_IDENTITY_OVERRIDE}" ]]; then
  SIGNING_IDENTITY="${SIGNING_IDENTITY_OVERRIDE}"
elif print -r -- "${SIGNATURE_DETAILS}" | /usr/bin/grep -q '^Signature=adhoc$'; then
  SIGNING_IDENTITY="-"
else
  SIGNING_IDENTITY=$(print -r -- "${SIGNATURE_DETAILS}" \
    | /usr/bin/awk -F= '$1 == "Authority" { print substr($0, index($0, "=") + 1); exit }')
  if [[ -z "${SIGNING_IDENTITY}" ]]; then
    print -u2 "The installed app's signing identity could not be determined."
    print -u2 "Pass --sign-identity with a valid identity to sign the update."
    exit 1
  fi
fi

# Run all checks and the release build while the installed app is still
# untouched. A failed build never stops the running application.
swift run AIShortcutsCoreChecks
./Scripts/check_voice.sh
./Scripts/check_dictionary.sh
./Scripts/check_panels.sh
swift run AIShortcutsRenderingChecks
swift build -c release --product AIShortcuts
BIN_PATH=$(swift build -c release --show-bin-path)
RELEASE_BINARY="${BIN_PATH}/${EXECUTABLE_NAME}"
RENDERING_RESOURCE_BUNDLE="${BIN_PATH}/${RENDERING_BUNDLE_NAME}"
if [[ ! -x "${RELEASE_BINARY}" ]]; then
  print -u2 "The release executable was not produced at ${RELEASE_BINARY}."
  exit 1
fi
if [[ ! -d "${RENDERING_RESOURCE_BUNDLE}" ]]; then
  print -u2 "The rendering resource bundle was not produced."
  exit 1
fi
if [[ ! -f "${ICON_PATH}" ]]; then
  print -u2 "The AI Shortcuts app icon is missing."
  exit 1
fi

STAGING_ROOT=$(/usr/bin/mktemp -d "${APP_PARENT}/.AI Shortcuts.update.XXXXXX")
STAGED_APP="${STAGING_ROOT}/${APP_NAME}.app"
BACKUP_APP="${APP_PARENT}/${APP_NAME}.app.previous.$(/bin/date '+%Y%m%d-%H%M%S').$$"

cleanup() {
  local update_exit_code=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [[ "${UPDATE_STARTED}" == true && "${UPDATE_COMPLETED}" == false \
        && "${ROLLBACK_ATTEMPTED}" == false ]]; then
    if [[ "${BACKUP_MOVE_STARTED}" == true && -d "${BACKUP_APP}" ]]; then
      restore_previous "the update was interrupted before launch verification completed." || true
    elif [[ -d "${APP_PATH}" ]]; then
      if ! bootout_agent || ! bootstrap_and_kickstart; then
        print -u2 "The unchanged app remains installed but could not be relaunched."
      fi
    fi
  fi
  if [[ -n "${STAGING_ROOT}" && -d "${STAGING_ROOT}" ]]; then
    /bin/rm -rf "${STAGING_ROOT}" || true
  fi
  exit "${update_exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -e "${BACKUP_APP}" || -L "${BACKUP_APP}" ]]; then
  print -u2 "The backup destination already exists: ${BACKUP_APP}"
  exit 1
fi

# Copy the complete installed bundle first. This retains its Info.plist and
# every resource/metadata entry while the three build outputs are refreshed.
/usr/bin/ditto "${APP_PATH}" "${STAGED_APP}"
/bin/cp "${RELEASE_BINARY}" "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
/bin/chmod 755 "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
/bin/rm -rf "${STAGED_APP}/Contents/Resources/${RENDERING_BUNDLE_NAME}"
/usr/bin/ditto "${RENDERING_RESOURCE_BUNDLE}" \
  "${STAGED_APP}/Contents/Resources/${RENDERING_BUNDLE_NAME}"
/bin/cp "${ICON_PATH}" "${STAGED_APP}/Contents/Resources/AIShortcutsLogo.icns"

if ! /usr/bin/cmp -s "${INSTALLED_INFO_PLIST}" "${STAGED_APP}/Contents/Info.plist"; then
  print -u2 "The staged update changed the installed Info.plist metadata."
  exit 1
fi

/usr/bin/codesign --force --deep --sign "${SIGNING_IDENTITY}" \
  --identifier "${BUNDLE_ID}" "${STAGED_APP}"
/usr/bin/codesign --verify --deep --strict "${STAGED_APP}"
if ! /usr/bin/cmp -s "${INSTALLED_INFO_PLIST}" "${STAGED_APP}/Contents/Info.plist"; then
  print -u2 "Code signing changed the installed Info.plist metadata."
  exit 1
fi
STAGED_SIGNATURE_DETAILS=$(/usr/bin/codesign --display --verbose=4 "${STAGED_APP}" 2>&1)
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  if ! print -r -- "${STAGED_SIGNATURE_DETAILS}" | /usr/bin/grep -q '^Signature=adhoc$'; then
    print -u2 "The staged app did not retain its ad-hoc signing mode."
    exit 1
  fi
else
  STAGED_AUTHORITY=$(print -r -- "${STAGED_SIGNATURE_DETAILS}" \
    | /usr/bin/awk -F= '$1 == "Authority" { print substr($0, index($0, "=") + 1); exit }')
  if [[ -z "${STAGED_AUTHORITY}" \
        || ( -z "${SIGNING_IDENTITY_OVERRIDE}" && "${STAGED_AUTHORITY}" != "${SIGNING_IDENTITY}" ) ]]; then
    print -u2 "The staged app was signed by ${STAGED_AUTHORITY}, expected ${SIGNING_IDENTITY}."
    exit 1
  fi
fi

installed_pids() {
  local pid command
  for pid in $(/usr/bin/pgrep -x "${EXECUTABLE_NAME}" 2>/dev/null || true); do
    command=$(/bin/ps -p "${pid}" -o command= 2>/dev/null \
      | /usr/bin/sed 's/^[[:space:]]*//') || continue
    if [[ "${command}" == "${INSTALLED_EXECUTABLE}" ]]; then
      print "${pid}"
    fi
  done
}

wait_for_no_installed_process() {
  for _ in {1..50}; do
    [[ -z "$(installed_pids)" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

stop_installed_process() {
  local pid
  for pid in $(installed_pids); do
    /bin/kill -TERM "${pid}" >/dev/null 2>&1 || true
  done
  wait_for_no_installed_process
}

wait_for_agent_process() {
  local details pid command second_details second_pid second_command
  local launch_deadline=$(( SECONDS + 10 ))
  while (( SECONDS < launch_deadline )); do
    details=$(/bin/launchctl print "${AGENT_TARGET}" 2>/dev/null || true)
    pid=$(print -r -- "${details}" \
      | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    if [[ "${pid}" == <-> ]] && /bin/kill -0 "${pid}" >/dev/null 2>&1; then
      command=$(/bin/ps -p "${pid}" -o command= 2>/dev/null \
        | /usr/bin/sed 's/^[[:space:]]*//')
      if [[ "${command}" == "${INSTALLED_EXECUTABLE}" ]]; then
        # Require the exact LaunchAgent PID/path to remain alive across a
        # second observation beyond SingleInstanceLock's two-second timeout;
        # a duplicate can otherwise appear healthy before it exits.
        /bin/sleep 2.2
        second_details=$(/bin/launchctl print "${AGENT_TARGET}" 2>/dev/null || true)
        second_pid=$(print -r -- "${second_details}" \
          | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
        second_command=$(/bin/ps -p "${second_pid}" -o command= 2>/dev/null \
          | /usr/bin/sed 's/^[[:space:]]*//')
        if [[ "${second_pid}" == "${pid}" \
              && "${second_command}" == "${INSTALLED_EXECUTABLE}" ]] \
              && /bin/kill -0 "${second_pid}" >/dev/null 2>&1
        then
          return 0
        fi
      fi
    fi
    /bin/sleep 0.1
  done
  return 1
}

bootout_agent() {
  if ! /bin/launchctl bootout "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1; then
    if /bin/launchctl print "${AGENT_TARGET}" >/dev/null 2>&1; then
      print -u2 "The LaunchAgent could not be stopped; leaving the installed app intact."
      return 1
    fi
  fi
  return 0
}

bootstrap_and_kickstart() {
  /bin/launchctl bootstrap "gui/${UID}" "${AGENT_PATH}" || return 1
  /bin/launchctl kickstart "${AGENT_TARGET}" || return 1
  wait_for_agent_process
}

restore_previous() {
  local reason="$1"
  ROLLBACK_ATTEMPTED=true
  print -u2 "Update failed: ${reason}"
  if [[ ! -d "${BACKUP_APP}" ]]; then
    print -u2 "The previous app backup is missing at ${BACKUP_APP}; leaving the installed app intact."
    return 1
  fi
  bootout_agent || return 1
  if ! stop_installed_process; then
    print -u2 "The failed installed executable did not exit safely; leaving the backup at ${BACKUP_APP}."
    return 1
  fi
  if [[ -e "${APP_PATH}" || -L "${APP_PATH}" ]]; then
    /bin/rm -rf "${APP_PATH}" || return 1
  fi
  /bin/mv "${BACKUP_APP}" "${APP_PATH}" || return 1
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -f "${APP_PATH}" >/dev/null 2>&1 || true
  if bootstrap_and_kickstart; then
    print -u2 "Restored and relaunched the previous app."
    return 0
  fi
  print -u2 "The previous app was restored at ${APP_PATH}, but it did not stay running."
  return 1
}

# Do not touch any other process. A manual development copy has a different
# executable path and is intentionally ignored.
UPDATE_STARTED=true
if ! bootout_agent; then
  UPDATE_STARTED=false
  exit 1
fi
if ! stop_installed_process; then
  ROLLBACK_ATTEMPTED=true
  print -u2 "The installed app did not exit safely; the update was not applied."
  /bin/launchctl bootstrap "gui/${UID}" "${AGENT_PATH}" >/dev/null 2>&1 || true
  exit 1
fi

if [[ -e "${BACKUP_APP}" || -L "${BACKUP_APP}" ]]; then
  print -u2 "The backup destination already exists: ${BACKUP_APP}"
  exit 1
fi
BACKUP_MOVE_STARTED=true
if ! /bin/mv "${APP_PATH}" "${BACKUP_APP}"; then
  print -u2 "Could not create the previous app backup at ${BACKUP_APP}."
  exit 1
fi
if ! /bin/mv "${STAGED_APP}" "${APP_PATH}"; then
  restore_previous "could not move the verified replacement into place." || true
  exit 1
fi

"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
  -f "${APP_PATH}" >/dev/null 2>&1 || true

if [[ "${RESET_PERMISSIONS}" == true ]]; then
  print "Resetting this app's Accessibility, Screen Recording, and Automation decisions as requested."
  for PERMISSION_SERVICE in Accessibility ScreenCapture AppleEvents; do
    /usr/bin/tccutil reset "${PERMISSION_SERVICE}" "${BUNDLE_ID}" >/dev/null 2>&1 \
      || print -u2 "Could not reset ${PERMISSION_SERVICE} permission."
  done
  /usr/bin/defaults write "${BUNDLE_ID}" permissionsRequested.v1 -bool false \
    || print -u2 "Warning: the app permission onboarding preference could not be reset."
fi

if ! bootstrap_and_kickstart; then
  restore_previous "the replacement did not remain alive under its LaunchAgent." || true
  exit 1
fi

UPDATE_COMPLETED=true
print "Updated ${APP_PATH}"
print "Previous app backup: ${BACKUP_APP}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  print "Signing: ad-hoc; macOS may request permission again for the changed signature."
else
  print "Signing identity: ${SIGNING_IDENTITY}"
fi
