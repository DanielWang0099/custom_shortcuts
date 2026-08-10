#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
TEMPLATE_PATH="${SCRIPT_DIR}/family_installer_template.command"
OUTPUT_DIR="${PROJECT_DIR}/dist"
OUTPUT_PATH="${OUTPUT_DIR}/AI Shortcuts Family Installer.command"
KEY_SOURCE_PATH="${HOME}/Documents/GitHub/japanese-practice/vocabulary-flashcard-practice/.env.local"
APP_NAME="AI Shortcuts"
EXECUTABLE_NAME="AIShortcuts"
BUNDLE_ID="com.susanawang.aishortcuts"

if [[ ! -f "${KEY_SOURCE_PATH}" ]]; then
    print "The configured API key source is unavailable."
    exit 1
fi

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
if [[ ${#API_KEY} -le 20 ]]; then
    print "The configured API key is missing or invalid."
    exit 1
fi

cd "${PROJECT_DIR}"
swift run AIShortcutsCoreChecks
swift build -c release --product AIShortcuts --triple arm64-apple-macosx13.0
swift build -c release --product AIShortcuts --triple x86_64-apple-macosx13.0

TEMP_PATH=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-shortcuts-package.XXXXXX")
trap 'unset API_KEY; /bin/rm -rf "${TEMP_PATH}"' EXIT
APP_PATH="${TEMP_PATH}/${APP_NAME}.app"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
/bin/mkdir -p "${MACOS_PATH}" "${CONTENTS_PATH}/Resources" "${OUTPUT_DIR}"

/usr/bin/lipo -create \
    "${PROJECT_DIR}/.build/arm64-apple-macosx/release/${EXECUTABLE_NAME}" \
    "${PROJECT_DIR}/.build/x86_64-apple-macosx/release/${EXECUTABLE_NAME}" \
    -output "${MACOS_PATH}/${EXECUTABLE_NAME}"
/bin/chmod 755 "${MACOS_PATH}/${EXECUTABLE_NAME}"

INFO_PLIST="${CONTENTS_PATH}/Info.plist"
/usr/bin/plutil -create xml1 "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string "en" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleDisplayName -string "${APP_NAME}" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleExecutable -string "${EXECUTABLE_NAME}" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleIdentifier -string "${BUNDLE_ID}" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleName -string "${APP_NAME}" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleShortVersionString -string "1.1.0" "${INFO_PLIST}"
/usr/bin/plutil -insert CFBundleVersion -string "2" "${INFO_PLIST}"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "13.0" "${INFO_PLIST}"
/usr/bin/plutil -insert LSUIElement -bool true "${INFO_PLIST}"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "${INFO_PLIST}"
/usr/bin/plutil -insert NSPrincipalClass -string "NSApplication" "${INFO_PLIST}"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string \
    "AI Shortcuts asks Finder for the selected file or folder so it can copy the complete POSIX path." "${INFO_PLIST}"
/usr/bin/plutil -insert NSScreenCaptureUsageDescription -string \
    "AI Shortcuts captures only the screen region you select for AI OCR and Calculate." "${INFO_PLIST}"

/usr/bin/codesign --force --deep --sign - --identifier "${BUNDLE_ID}" "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict "${APP_PATH}"
PAYLOAD_ZIP="${TEMP_PATH}/AI-Shortcuts.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${PAYLOAD_ZIP}"

/bin/cp "${TEMPLATE_PATH}" "${OUTPUT_PATH}"
/usr/bin/base64 < "${PAYLOAD_ZIP}" >> "${OUTPUT_PATH}"
print '__AI_SHORTCUTS_KEY_PAYLOAD__' >> "${OUTPUT_PATH}"
print -rn -- "${API_KEY}" | /usr/bin/base64 >> "${OUTPUT_PATH}"
/bin/chmod 700 "${OUTPUT_PATH}"

if /usr/bin/grep -Fq -- "${API_KEY}" "${OUTPUT_PATH}"; then
    print "Packaging refused because the key appeared as plaintext."
    exit 1
fi
KEY_MARKER_LINE=$(/usr/bin/grep -n '^__AI_SHORTCUTS_KEY_PAYLOAD__$' "${OUTPUT_PATH}" | /usr/bin/cut -d: -f1)
PACKAGED_KEY=$(/usr/bin/tail -n "+$((KEY_MARKER_LINE + 1))" "${OUTPUT_PATH}" | /usr/bin/base64 -D)
if [[ "${PACKAGED_KEY}" != "${API_KEY}" ]]; then
    print "Packaging refused because the key payload did not verify."
    exit 1
fi
unset API_KEY PACKAGED_KEY

print "Created ${OUTPUT_PATH}"
print "Compatibility: macOS 13+; Apple Silicon and Intel."
