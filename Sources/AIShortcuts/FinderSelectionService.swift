import AppKit
import CoreServices
import Foundation
import OSLog

struct FinderPathResult: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case selection
    }

    let paths: [String]
    let source: Source
}

enum FinderAutomationAuthorization: Equatable, Sendable {
    case unknown
    case granted
    case notDetermined
    case denied
    case finderNotRunning
    case unavailable
}

enum FinderPathError: LocalizedError {
    case appleScriptFailed(String)
    case notAuthorized(target: String)

    var errorDescription: String? {
        switch self {
        case let .appleScriptFailed(message):
            "Finder did not return a path (\(message))."
        case let .notAuthorized(target):
            "AI Shortcuts is not authorized to control \(target). Grant Automation permission in System Settings."
        }
    }
}

@MainActor
final class FinderSelectionService {
    private static let selectionScriptSource = """
    on getFinderPaths()
        tell application "Finder"
            if not running then return {"notRunning", ""}
            set selectedItems to selection
            if (count of selectedItems) > 0 then
                set out to ""
                repeat with f in selectedItems
                    try
                        set out to out & POSIX path of (f as alias) & linefeed
                    end try
                end repeat
                return {"selection", out}
            end if
            return {"empty", ""}
        end tell
    end getFinderPaths

    getFinderPaths()
    """

    private let logger = Logger(
        subsystem: AppConfiguration.bundleIdentifier,
        category: "finder"
    )
    private lazy var selectionScript = NSAppleScript(source: Self.selectionScriptSource)

    func prepare() {
        _ = selectionScript
    }

    func authorizationState(
        requestIfNeeded: Bool
    ) async -> FinderAutomationAuthorization {
        return await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            guard let targetDescriptor = target.aeDesc else {
                return .unavailable
            }
            let status = AEDeterminePermissionToAutomateTarget(
                targetDescriptor,
                typeWildCard,
                typeWildCard,
                requestIfNeeded
            )
            switch status {
            case noErr:
                return .granted
            case OSStatus(errAEEventWouldRequireUserConsent):
                return .notDetermined
            case OSStatus(errAEEventNotPermitted):
                return .denied
            case OSStatus(procNotFound):
                return .finderNotRunning
            default:
                return .unavailable
            }
        }.value
    }

    func currentPaths() async throws -> FinderPathResult? {
        // Returns an AppleEvent list of two items: a source label and the
        // newline-joined full POSIX paths. A missing selection returns
        // "empty" instead of silently substituting the front-window folder.
        guard let appleScript = selectionScript else {
            throw FinderPathError.appleScriptFailed("Could not compile the AppleScript source.")
        }
        var errorInfo: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let raw = message(from: errorInfo)
            let errorNumber = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.int32Value
            if let errorNumber,
               errorNumber == OSStatus(errAEEventNotPermitted)
                || errorNumber == OSStatus(errAEEventWouldRequireUserConsent)
            {
                throw FinderPathError.notAuthorized(target: "Finder")
            }
            throw FinderPathError.appleScriptFailed(raw)
        }

        // The script returns a 2-item list. NSAppleEventDescriptor uses
        // 1-based indexing for atIndex.
        guard descriptor.numberOfItems == 2 else {
            return nil
        }
        let sourceLabel = descriptor.atIndex(1)?.stringValue ?? ""
        let raw = descriptor.atIndex(2)?.stringValue ?? ""

        let resolved = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map(canonicalize(path:))

        guard !resolved.isEmpty else {
            return nil
        }

        guard sourceLabel == "selection" else {
            return nil
        }
        return FinderPathResult(paths: resolved, source: .selection)
    }

    private func message(from errorInfo: NSDictionary) -> String {
        if let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return errorInfo.description
    }

    private func canonicalize(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.resolvingSymlinksInPath().path
    }
}
