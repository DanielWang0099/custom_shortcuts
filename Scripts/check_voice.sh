#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "${SCRIPT_DIR:h}"
swift build --product AIShortcutsCoreChecks
BUILD_PATH=$(swift build --show-bin-path)
CHECK_PATH="${BUILD_PATH}/voice-checks"
mkdir -p "${CHECK_PATH}"
rg '/AIShortcutsCore\.build/' \
  "${BUILD_PATH}/AIShortcutsCoreChecks.product/Objects.LinkFileList" \
  > "${CHECK_PATH}/core-objects.rsp"

xcrun swiftc -swift-version 6 -parse-as-library \
  -I "${BUILD_PATH}/Modules" \
  Sources/AIShortcuts/ChromeVoiceSessionService.swift \
  Tests/AIShortcutsVoiceChecks/main.swift \
  @"${CHECK_PATH}/core-objects.rsp" \
  -framework AppKit -framework ApplicationServices \
  -o "${CHECK_PATH}/VoiceChecks"
"${CHECK_PATH}/VoiceChecks" "$@"
