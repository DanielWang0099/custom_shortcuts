#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
ICON_WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-shortcuts-icon.XXXXXX")
trap '/bin/rm -rf "${ICON_WORK_DIR}"' EXIT
ICONSET_PATH="${ICON_WORK_DIR}/AIShortcutsLogo.iconset"
/bin/mkdir -p "${ICONSET_PATH}"

cat > "${ICON_WORK_DIR}/IconMain.swift" <<'SWIFT'
import AppKit
import Foundation

@main
struct GenerateIcon {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: pixels * 4, bitsPerPixel: 32
                )!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                AIShortcutsLogo.appIconImage(size: CGFloat(pixels)).draw(
                    in: NSRect(x: 0, y: 0, width: pixels, height: pixels)
                )
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                let filename = "icon_\(points)x\(points)\(suffix).png"
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent(filename))
            }
        }
    }
}
SWIFT

xcrun swiftc -swift-version 6 -parse-as-library \
  "${PROJECT_DIR}/Sources/AIShortcuts/AIShortcutsLogo.swift" \
  "${ICON_WORK_DIR}/IconMain.swift" \
  -o "${ICON_WORK_DIR}/GenerateIcon"
"${ICON_WORK_DIR}/GenerateIcon" "${ICONSET_PATH}"
/usr/bin/iconutil -c icns "${ICONSET_PATH}" -o "${PROJECT_DIR}/Resources/AIShortcutsLogo.icns"
print "Updated Resources/AIShortcutsLogo.icns"
