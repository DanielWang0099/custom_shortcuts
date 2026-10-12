#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "${SCRIPT_DIR:h}"
swift build --product AIShortcutsRenderingChecks
BUILD_PATH=$(swift build --show-bin-path)
CHECK_PATH="${BUILD_PATH}/panel-checks"
mkdir -p "${CHECK_PATH}"
rg '/AIShortcuts(Core|Rendering)\.build/' \
  "${BUILD_PATH}/AIShortcutsRenderingChecks.product/Objects.LinkFileList" \
  > "${CHECK_PATH}/core-objects.rsp"

xcrun swiftc -swift-version 6 -parse-as-library \
  -I "${BUILD_PATH}/Modules" \
  Sources/AIShortcuts/TransientPanelDismissal.swift \
  Sources/AIShortcuts/ExplanationPanelController.swift \
  Sources/AIShortcuts/HUDController.swift \
  Sources/AIShortcuts/ShortcutGuideWindowController.swift \
  Sources/AIShortcuts/ModelSettingsWindowController.swift \
  Sources/AIShortcuts/WelcomeWindowController.swift \
  Sources/AIShortcuts/PromptPanelController.swift \
  Sources/AIShortcuts/InsertPanelController.swift \
  Sources/AIShortcuts/InsertLibraryStore.swift \
  Sources/AIShortcuts/InputLockPanelController.swift \
  Sources/AIShortcuts/InputLockService.swift \
  Sources/AIShortcuts/ShortcutUIStyle.swift \
  Sources/AIShortcuts/AIShortcutsLogo.swift \
  Sources/AIShortcuts/AppStateStore.swift \
  Sources/AIShortcuts/AppConfiguration.swift \
  Tests/AIShortcutsPanelChecks/main.swift \
  @"${CHECK_PATH}/core-objects.rsp" \
  -framework AppKit -framework WebKit -framework CoreGraphics \
  -framework CoreText -framework Security -framework Carbon \
  -o "${CHECK_PATH}/PanelChecks"
"${CHECK_PATH}/PanelChecks" --previews "${CHECK_PATH}/previews"
