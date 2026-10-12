#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "${PROJECT_DIR}"

swift build --product AIShortcutsRenderingChecks
BUILD_PATH=$(swift build --show-bin-path)
CHECK_PATH="${BUILD_PATH}/dictionary-checks"
mkdir -p "${CHECK_PATH}"
rg '/AIShortcuts(Core|Rendering)\.build/' \
  "${BUILD_PATH}/AIShortcutsRenderingChecks.product/Objects.LinkFileList" \
  > "${CHECK_PATH}/core-objects.rsp"

xcrun swiftc -swift-version 6 -parse-as-library \
  -I "${BUILD_PATH}/Modules" \
  Sources/AIShortcuts/DictionaryPanelController.swift \
  Sources/AIShortcuts/DictionaryNativeServices.swift \
  Sources/AIShortcuts/ShortcutUIStyle.swift \
  Sources/AIShortcuts/TransientPanelDismissal.swift \
  Sources/AIShortcuts/AppStateStore.swift \
  Sources/AIShortcuts/AppConfiguration.swift \
  Sources/AIShortcuts/SelectionService.swift \
  Sources/AIShortcuts/ScreenshotService.swift \
  Sources/AIShortcuts/DictionaryCoordinator.swift \
  Sources/AIShortcuts/HotKeyManager.swift \
  Tests/AIShortcutsDictionaryChecks/main.swift \
  Tests/AIShortcutsDictionaryChecks/PanelChecks.swift \
  Tests/AIShortcutsDictionaryChecks/ActivationChecks.swift \
  Tests/AIShortcutsDictionaryChecks/CaptureChecks.swift \
  Tests/AIShortcutsDictionaryChecks/LiveAIChecks.swift \
  @"${CHECK_PATH}/core-objects.rsp" \
  -framework AppKit -framework Carbon -framework NaturalLanguage \
  -framework CoreServices -framework AVFoundation -framework ApplicationServices -framework Security \
  -framework LocalAuthentication \
  -o "${CHECK_PATH}/DictionaryChecks"

"${CHECK_PATH}/DictionaryChecks" --previews "${CHECK_PATH}/previews" "$@" | tee "${CHECK_PATH}/checks.log"
rg -q '^All native dictionary checks passed\.$' "${CHECK_PATH}/checks.log"
