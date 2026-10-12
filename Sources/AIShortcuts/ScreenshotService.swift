import AppKit
import Foundation

struct ScreenshotCapture: Sendable {
    let pngData: Data
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
    typealias ProcessRunner = @MainActor ([String]) async throws -> Int32

    private var activeProcess: Process?
    private let processRunner: ProcessRunner?

    init(processRunner: ProcessRunner? = nil) {
        self.processRunner = processRunner
    }

    func cancelCapture() {
        guard let activeProcess, activeProcess.isRunning else {
            return
        }
        activeProcess.terminate()
    }

    func captureSelection(preserveClipboard: Bool = false) async throws -> ScreenshotCapture? {
        if preserveClipboard {
            return try await captureSelectionToTemporaryFile()
        }

        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        let status = try await runScreenshotProcess(arguments: ["-i", "-s", "-c", "-x"])
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

        if let pngData = pasteboard.data(forType: .png) {
            // `screencapture` already produced the upload format. Returning it
            // directly avoids a full-resolution bitmap decode and re-encode.
            return ScreenshotCapture(pngData: pngData)
        }

        guard let sourceData = pasteboard.data(forType: .tiff) else {
            throw ScreenshotError.missingImage
        }
        guard let bitmap = NSBitmapImageRep(data: sourceData) else {
            throw ScreenshotError.conversionFailed
        }
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.conversionFailed
        }

        return ScreenshotCapture(pngData: pngData)
    }

    private func captureSelectionToTemporaryFile() async throws -> ScreenshotCapture? {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("ai-shortcuts-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer {
            // The screenshot is consumed into memory before returning. Do not
            // leave cropped screen contents in the temporary directory.
            try? fileManager.removeItem(at: url)
        }

        let status = try await runScreenshotProcess(
            arguments: ["-i", "-s", "-x", "-t", "png", url.path]
        )
        guard status == 0 else {
            // Escape exits screencapture without producing a file. Treat that
            // as a cancelled selection so callers can show their manual path.
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            throw ScreenshotError.commandFailed(status)
        }
        guard let pngData = try? Data(contentsOf: url), !pngData.isEmpty else {
            return nil
        }
        return ScreenshotCapture(pngData: pngData)
    }

    private func runScreenshotProcess(arguments: [String]) async throws -> Int32 {
        if let processRunner {
            return try await processRunner(arguments)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            activeProcess = process
            process.terminationHandler = { [weak self] completed in
                let status = completed.terminationStatus
                Task(priority: .userInitiated) { @MainActor in
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
