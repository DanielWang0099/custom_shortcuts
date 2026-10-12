import CoreGraphics
import Foundation

public struct ChromeVoiceTabReference: Equatable, Sendable {
    public let processIdentifier: Int32
    public let tabIdentifier: Int

    public init(processIdentifier: Int32, tabIdentifier: Int) {
        self.processIdentifier = processIdentifier
        self.tabIdentifier = tabIdentifier
    }
}

/// Chrome's scripting `front window` can be minimized or on another Space.
/// Correlate the tracked tab's window with the actual focused AX window instead.
public enum ChromeVoiceTargetPolicy {
    public static func matchesFocusedWindow(
        tabIsSelected: Bool,
        windowIsMinimized: Bool,
        scriptingBounds: CGRect,
        focusedBounds: CGRect
    ) -> Bool {
        guard tabIsSelected, !windowIsMinimized,
              scriptingBounds.width > 0, scriptingBounds.height > 0,
              focusedBounds.width > 0, focusedBounds.height > 0 else { return false }
        return zip(
            [scriptingBounds.minX, scriptingBounds.minY, scriptingBounds.width, scriptingBounds.height],
            [focusedBounds.minX, focusedBounds.minY, focusedBounds.width, focusedBounds.height]
        ).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= 2 }
    }
}

/// All startup stages, including one optional reload, share this monotonic budget.
public struct ChromeVoiceLaunchBudget: Sendable {
    public static let timeout: TimeInterval = 8
    public let deadline: TimeInterval

    public init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        deadline = now + Self.timeout
    }

    public func remaining(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, deadline - now)
    }

    public func stageDeadline(
        duration: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        min(deadline, now + duration)
    }
}

public enum ChromeVoiceActivity: Equatable, Sendable {
    case active
    case inactive
    case unknown
}

public enum ChromeVoiceSessionDecision: Equatable, Sendable {
    case createNewTab
    case resumeTrackedTab
    case inspectTrackedTab
}

/// A bounded readiness timeout can recover a remembered tab whose voice UI vanished.
public enum ChromeVoiceReloadPolicy {
    public static func shouldReload(
        isResuming: Bool,
        reloadAttempted: Bool,
        startButtonCount: Int,
        endButtonCount: Int,
        microphoneCount: Int,
        isRecording: Bool,
        isConnecting: Bool
    ) -> Bool {
        isResuming
            && !reloadAttempted
            && startButtonCount == 0
            && endButtonCount == 0
            && microphoneCount == 0
            && !isRecording
            && !isConnecting
    }
}

/// In-memory policy for the single Chrome tab owned by the voice shortcut.
public struct ChromeVoiceSessionMemory: Sendable {
    public let idleTimeout: TimeInterval

    public private(set) var reference: ChromeVoiceTabReference?
    public private(set) var idleSince: Date?

    public init(idleTimeout: TimeInterval = 30 * 60) {
        self.idleTimeout = idleTimeout
    }

    public mutating func remember(
        _ reference: ChromeVoiceTabReference,
        now: Date = Date()
    ) {
        self.reference = reference
        // A newly opened tab can still be loading or waiting for permission.
        // Its idle window begins only when inactivity is actually observed.
        idleSince = nil
    }

    public mutating func observe(
        _ activity: ChromeVoiceActivity,
        now: Date = Date()
    ) {
        guard reference != nil else {
            return
        }
        switch activity {
        case .active:
            idleSince = nil
        case .inactive:
            if idleSince == nil {
                idleSince = now
            }
        case .unknown:
            break
        }
    }

    public mutating func decision(
        referenceIsValid: Bool,
        activity: ChromeVoiceActivity,
        now: Date = Date()
    ) -> ChromeVoiceSessionDecision {
        guard reference != nil, referenceIsValid else {
            reset()
            return .createNewTab
        }

        observe(activity, now: now)
        switch activity {
        case .active:
            return .resumeTrackedTab
        case .unknown:
            // A stale Accessibility element must not expire an ongoing call.
            return .inspectTrackedTab
        case .inactive:
            if let idleSince, now.timeIntervalSince(idleSince) >= idleTimeout {
                // Keep the reference until a replacement tab is remembered.
                // A fresh active observation may still override this decision.
                return .createNewTab
            }
            return .resumeTrackedTab
        }
    }

    public mutating func reset() {
        reference = nil
        idleSince = nil
    }
}
