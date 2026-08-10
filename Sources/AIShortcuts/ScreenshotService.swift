import AppKit
import Foundation

struct ScreenshotCapture: Sendable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenshotError: LocalizedError {
    case commandFailed(Int32)
    case missingImage
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case let .commandFailed(status):
            "macOS screenshot selection failed with status \(status)."
        case .missingImage:
            "The screenshot was not available on the clipboard."
        case .conversionFailed:
            "The screenshot could not be converted to PNG."
        }
    }
}

@MainActor
final class ScreenshotService {
    private var activeProcess: Process?

    func cancelCapture() {
        guard let activeProcess, activeProcess.isRunning else {
            return
        }
        activeProcess.terminate()
    }

    func captureSelection() async throws -> ScreenshotCapture? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        let status = try await runScreenshotProcess()
        if status != 0 {
            // Escape normally exits without producing new clipboard data.
            if pasteboard.changeCount == originalChangeCount {
                return nil
            }
            throw ScreenshotError.commandFailed(status)
        }
        guard pasteboard.changeCount != originalChangeCount else {
            return nil
        }

        let sourceData =
            pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
        guard let sourceData else {
            throw ScreenshotError.missingImage
        }
        guard let bitmap = NSBitmapImageRep(data: sourceData) else {
            throw ScreenshotError.conversionFailed
        }
        let pngData: Data
        if pasteboard.data(forType: .png) != nil {
            pngData = sourceData
        } else {
            guard let converted = bitmap.representation(using: .png, properties: [:]) else {
                throw ScreenshotError.conversionFailed
            }
            pngData = converted
        }

        return ScreenshotCapture(
            pngData: pngData,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh
        )
    }

    private func runScreenshotProcess() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-c", "-x"]
            activeProcess = process
            process.terminationHandler = { [weak self] completed in
                let status = completed.terminationStatus
                Task { @MainActor in
                    if self?.activeProcess === completed {
                        self?.activeProcess = nil
                    }
                    continuation.resume(returning: status)
                }
            }
            do {
                try process.run()
            } catch {
                activeProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
