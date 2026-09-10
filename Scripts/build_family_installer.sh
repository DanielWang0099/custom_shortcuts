#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
TEMPLATE_PATH="${SCRIPT_DIR}/family_installer_template.command"
OUTPUT_DIR="${PROJECT_DIR}/dist"
OUTPUT_PATH="${OUTPUT_DIR}/AI Shortcuts Installer.command"
APP_NAME="AI Shortcuts"
EXECUTABLE_NAME="AIShortcuts"
BUNDLE_ID="com.susanawang.aishortcuts"

cd "${PROJECT_DIR}"
swift run AIShortcutsCoreChecks
swift run AIShortcutsRenderingChecks
swift build -c release --product AIShortcuts --triple arm64-apple-macosx13.0
swift build -c release --product AIShortcuts --triple x86_64-apple-macosx13.0

TEMP_PATH=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-shortcuts-package.XXXXXX")
trap '/bin/rm -rf "${TEMP_PATH}"' EXIT
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
/bin/chmod 700 "${OUTPUT_PATH}"

print "Created ${OUTPUT_PATH}"
print "Compatibility: macOS 13+; Apple Silicon and Intel."
print "No API key is embedded; each user configures their own key on first launch."
