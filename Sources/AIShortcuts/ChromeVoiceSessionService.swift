import AppKit
import ApplicationServices
import AIShortcutsCore
import Foundation

enum ChromeVoiceLaunchOutcome: Sendable {
    case startedNew
    case resumed
    case alreadyActive
}

enum ChromeVoiceError: LocalizedError, Sendable {
    case accessibilityDenied
    case automationDenied
    case chromeUnavailable
    case automationFailed(Int)
    case accessibilityUnavailable
    case targetChanged
    case ambiguousControls
    case controlsUnavailable
    case reloadUnavailable
    case unsupportedPress
    case startFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Allow AI Shortcuts in System Settings → Privacy & Security → Accessibility, then retry."
        case .automationDenied:
            "Allow AI Shortcuts to control Google Chrome in System Settings → Privacy & Security → Automation, then retry."
        case .chromeUnavailable:
            "Google Chrome is not installed. Install Chrome before using ChatGPT Voice."
        case let .automationFailed(number):
            "Chrome automation failed (error \(number)). Check Chrome and retry."
        case .accessibilityUnavailable:
            "Chrome's accessible page is not available. Check the ChatGPT tab and retry."
        case .targetChanged:
            "Chrome's selected tab changed during startup. Press ChatGPT Voice again to retry."
        case .ambiguousControls:
            "ChatGPT exposed more than one voice button. Check its open tab and retry."
        case .controlsUnavailable:
            "ChatGPT's voice button was not ready. Check sign-in, voice setup, and microphone permission in Chrome, then retry."
        case .reloadUnavailable:
            "Chrome's Reload button could not be pressed through Accessibility. Refresh the ChatGPT tab and retry."
        case .unsupportedPress:
            "ChatGPT's voice button could not be pressed through Accessibility. Check its open tab and retry."
        case .startFailed:
            "ChatGPT did not finish starting voice. Check voice setup and microphone permission in Chrome, then retry."
        }
    }
}

/// The façade belongs to the app's operation lifecycle. All blocking Apple
/// Events, Accessibility reads, and session state belong to one worker queue.
@MainActor
final class ChromeVoiceSessionService {
    private struct Launch {
        let identity: UUID
        let task: Task<ChromeVoiceLaunchOutcome, any Error>
        let cancellation: ChromeVoiceCancellation
    }

    private let worker = ChromeVoiceWorker()
    private var launch: Launch?

    func startOrResume() async throws -> ChromeVoiceLaunchOutcome {
        try Task.checkCancellation()
        let current: Launch
        if let launch {
            current = launch
        } else {
            let cancellation = ChromeVoiceCancellation()
            let task = Task { [worker] in
                try await worker.startOrResume(cancellation: cancellation)
            }
            current = Launch(identity: UUID(), task: task, cancellation: cancellation)
            launch = current
        }

        do {
            let outcome = try await withTaskCancellationHandler {
                try await current.task.value
            } onCancel: {
                current.cancellation.cancel()
                current.task.cancel()
            }
            if launch?.identity == current.identity {
                launch = nil
            }
            try Task.checkCancellation()
            return outcome
        } catch {
            if launch?.identity == current.identity {
                launch = nil
            }
            throw error
        }
    }

    func invalidate() {
        launch?.cancellation.cancel()
        launch?.task.cancel()
        launch = nil
        worker.invalidate()
    }
}

private final class ChromeVoiceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        if lock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }
}

/// @unchecked Sendable is limited to this queue-confined worker and its locked
/// cancellation flag. AXUIElement and NSAppleScript never cross the queue.
private final class ChromeVoiceWorker: @unchecked Sendable {
    private static let bundleIdentifier = "com.google.Chrome"
    private static let readinessTimeout: TimeInterval = 20
    private static let pollInterval: TimeInterval = 0.35
    private static let startLabels: Set<String> = [
        "start voice", "start voice mode", "start a voice conversation", "use voice mode",
        "开始语音", "開始語音", "開始語音模式",
    ]
    private static let endLabels: Set<String> = [
        "end voice", "end voice chat", "end voice mode", "exit voice", "exit voice mode",
        "结束语音", "結束語音", "结束语音聊天", "退出语音",
    ]
    private static let microphoneLabels: Set<String> = [
        "mute", "unmute", "mute microphone", "unmute microphone", "turn off microphone",
        "turn on microphone", "关闭麦克风", "打开麦克风", "开启麦克风", "關閉麥克風", "開啟麥克風",
    ]
    private static let connectingLabels: Set<String> = [
        "connecting", "connecting...", "connecting…", "连接中", "连接中...", "连接中…",
        "正在连接", "正在連線",
    ]
    private static let reloadLabels: Set<String> = [
        "reload", "reload page", "reload this page",
        "重新加载", "重新加载此页", "重新加载此页面", "重新加载网页",
        "重新載入", "重新載入此頁", "重新載入此頁面", "重新載入網頁",
    ]

    private struct TabLocation {
        let windowIdentifier: Int
        let tabIdentifier: Int
        let url: URL
        let isSelected: Bool
    }

    private struct Snapshot {
        let window: AXUIElement
        let webArea: AXUIElement
        let selectedTab: AXUIElement?
        let location: TabLocation
        let start: [AXUIElement]
        let end: [AXUIElement]
        let microphones: [AXUIElement]
        let reload: [AXUIElement]
        let connecting: Bool
        let recording: Bool

        var voiceUIActive: Bool { end.count == 1 && !microphones.isEmpty }

        var readyForVoice: Bool {
            start.count == 1 || (voiceUIActive && !connecting)
        }

        var activity: ChromeVoiceActivity {
            if voiceUIActive || recording { return .active }
            if start.count == 1, end.isEmpty, microphones.isEmpty, !connecting {
                return .inactive
            }
            return .unknown
        }
    }

    private struct RetainedTarget {
        let reference: ChromeVoiceTabReference
        let snapshot: Snapshot
    }

    private struct AXIdentity: Hashable {
        let element: AXUIElement

        static func == (lhs: Self, rhs: Self) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(element))
        }
    }

    private let queue = DispatchQueue(label: "AIShortcuts.chrome-voice", qos: .userInitiated)
    private var memory = ChromeVoiceSessionMemory()
    private var retainedTarget: RetainedTarget?
    private var trackedLaunchDate: Date?
    private var monitor: DispatchSourceTimer?

    deinit {
        monitor?.cancel()
    }

    func startOrResume(
        cancellation: ChromeVoiceCancellation
    ) async throws -> ChromeVoiceLaunchOutcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try launch(cancellation: cancellation))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func invalidate() {
        queue.async { [self] in
            reset()
        }
    }

    private func launch(
        cancellation: ChromeVoiceCancellation
    ) throws -> ChromeVoiceLaunchOutcome {
        try cancellation.check()
        guard AXIsProcessTrusted() else { throw ChromeVoiceError.accessibilityDenied }
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.bundleIdentifier
        ) != nil else { throw ChromeVoiceError.chromeUnavailable }

        var createdNew = false
        var reference: ChromeVoiceTabReference
        if let remembered = memory.reference,
           chromeMatches(remembered),
           try locate(remembered, cancellation: cancellation) != nil,
           try select(remembered, cancellation: cancellation) != nil {
            reference = remembered
        } else {
            reset()
            reference = try createOwnedTab(cancellation: cancellation)
            createdNew = true
        }

        try waitForChromeFocus(reference, cancellation: cancellation)
        var ready = try waitForLaunchControls(
            reference,
            isResuming: !createdNew,
            cancellation: cancellation
        )
        retain(ready, for: reference)
        // A previously unreadable or unselected tab is inspected after focusing
        // it. An active call overrides its old idle timestamp before expiry.
        if memory.decision(
            referenceIsValid: true,
            activity: ready.activity
        ) == .createNewTab, !createdNew {
            reference = try createOwnedTab(cancellation: cancellation)
            createdNew = true
            try waitForChromeFocus(reference, cancellation: cancellation)
            ready = try waitForControls(reference, starting: false, cancellation: cancellation)
            retain(ready, for: reference)
            memory.observe(ready.activity)
        }

        if ready.voiceUIActive {
            return createdNew ? .startedNew : .alreadyActive
        }

        // Re-read both the selected scripting ID and the semantic controls.
        // The nearby dictation button never matches these exact voice labels.
        let beforePress = try foregroundSnapshot(reference, cancellation: cancellation)
        retain(beforePress, for: reference)
        if beforePress.voiceUIActive {
            memory.observe(.active)
            return createdNew ? .startedNew : .alreadyActive
        }
        guard beforePress.start.count == 1, beforePress.end.isEmpty,
              let button = beforePress.start.first else {
            throw ChromeVoiceError.controlsUnavailable
        }
        _ = try verifySelected(reference, cancellation: cancellation)
        try cancellation.check()
        try press(button)

        // A press is sent only once. A timeout leaves the owned tab available
        // for an explicit retry, including when a permission/setup UI appears.
        let active = try waitForControls(reference, starting: true, cancellation: cancellation)
        retain(active, for: reference)
        memory.observe(.active)
        return createdNew ? .startedNew : .resumed
    }

    private func createOwnedTab(
        cancellation: ChromeVoiceCancellation
    ) throws -> ChromeVoiceTabReference {
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                activate
                set targetWindow to missing value
                repeat with candidateWindow in windows
                    if mode of candidateWindow is "normal" then
                        set targetWindow to candidateWindow
                        exit repeat
                    end if
                end repeat
                if targetWindow is missing value then
                    set targetWindow to make new window with properties {mode:"normal"}
                    set targetTab to active tab of targetWindow
                    set URL of targetTab to "https://chatgpt.com/"
                else
                    set minimized of targetWindow to false
                    set index of targetWindow to 1
                    set targetTab to make new tab at end of tabs of targetWindow with properties {URL:"https://chatgpt.com/"}
                    set active tab index of targetWindow to (count of tabs of targetWindow)
                end if
                return {id of targetWindow as text, id of targetTab as text, URL of targetTab, id of active tab of targetWindow as text}
            end tell
        end timeout
        """
        let descriptor = try execute(
            source,
            cancellation: cancellation,
            checkCancellationAfterExecution: false
        )
        guard let location = tabLocation(descriptor), let application = chrome() else {
            throw ChromeVoiceError.automationFailed(0)
        }
        let reference = ChromeVoiceTabReference(
            processIdentifier: application.processIdentifier,
            tabIdentifier: location.tabIdentifier
        )
        memory.remember(reference)
        trackedLaunchDate = application.launchDate
        retainedTarget = nil
        startMonitoring()
        // Preserve the creation receipt even if cancellation arrived while the
        // Apple Event was running. An explicit retry can reuse this same tab.
        try cancellation.check()
        return reference
    }

    private func locate(
        _ reference: ChromeVoiceTabReference,
        cancellation: ChromeVoiceCancellation?
    ) throws -> TabLocation? {
        guard chromeMatches(reference) else { return nil }
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                if not running then return {}
                repeat with candidateWindow in windows
                    if mode of candidateWindow is "normal" then
                        repeat with candidateTab in tabs of candidateWindow
                            if (id of candidateTab as text) is "\(reference.tabIdentifier)" then
                                return {id of candidateWindow as text, id of candidateTab as text, URL of candidateTab, id of active tab of candidateWindow as text}
                            end if
                        end repeat
                    end if
                end repeat
                return {}
            end tell
        end timeout
        """
        let descriptor = try execute(source, cancellation: cancellation)
        guard chromeMatches(reference), let location = tabLocation(descriptor),
              location.tabIdentifier == reference.tabIdentifier else { return nil }
        return location
    }

    private func select(
        _ reference: ChromeVoiceTabReference,
        cancellation: ChromeVoiceCancellation
    ) throws -> TabLocation? {
        guard chromeMatches(reference) else { return nil }
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                if not running then return {}
                repeat with candidateWindow in windows
                    if mode of candidateWindow is "normal" then
                        set tabIndex to 0
                        repeat with candidateTab in tabs of candidateWindow
                            set tabIndex to tabIndex + 1
                            if (id of candidateTab as text) is "\(reference.tabIdentifier)" then
                                set minimized of candidateWindow to false
                                set index of candidateWindow to 1
                                set active tab index of candidateWindow to tabIndex
                                activate
                                return {id of candidateWindow as text, id of candidateTab as text, URL of candidateTab, id of active tab of candidateWindow as text}
                            end if
                        end repeat
                    end if
                end repeat
                return {}
            end tell
        end timeout
        """
        let descriptor = try execute(source, cancellation: cancellation)
        guard chromeMatches(reference), let location = tabLocation(descriptor),
              location.tabIdentifier == reference.tabIdentifier else { return nil }
        return location
    }

    private func verifySelected(
        _ reference: ChromeVoiceTabReference,
        cancellation: ChromeVoiceCancellation
    ) throws -> TabLocation {
        try cancellation.check()
        guard chromeMatches(reference),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == reference.processIdentifier else { throw ChromeVoiceError.targetChanged }
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                if not running then return {}
                if (count of windows) is 0 then return {}
                if mode of front window is not "normal" then return {}
                if (id of active tab of front window as text) is not "\(reference.tabIdentifier)" then return {}
                return {id of front window as text, id of active tab of front window as text, URL of active tab of front window, id of active tab of front window as text}
            end tell
        end timeout
        """
        let descriptor = try execute(source, cancellation: cancellation)
        guard chromeMatches(reference),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == reference.processIdentifier,
              let location = tabLocation(descriptor), location.isSelected,
              location.tabIdentifier == reference.tabIdentifier else {
            throw ChromeVoiceError.targetChanged
        }
        return location
    }

    private func execute(
        _ source: String,
        cancellation: ChromeVoiceCancellation?,
        checkCancellationAfterExecution: Bool = true
    ) throws -> NSAppleEventDescriptor {
        try cancellation?.check()
        guard let script = NSAppleScript(source: source) else {
            throw ChromeVoiceError.automationFailed(0)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if checkCancellationAfterExecution {
            try cancellation?.check()
        }
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if number == Int(errAEEventNotPermitted)
                || number == Int(errAEEventWouldRequireUserConsent) {
                throw ChromeVoiceError.automationDenied
            }
            // Do not put browser URLs or AppleScript object descriptions in HUDs.
            throw ChromeVoiceError.automationFailed(number)
        }
        return descriptor
    }

    private func tabLocation(_ descriptor: NSAppleEventDescriptor) -> TabLocation? {
        guard descriptor.numberOfItems == 4,
              let rawWindow = descriptor.atIndex(1)?.stringValue,
              let windowIdentifier = Int(rawWindow), windowIdentifier > 0,
              let rawTab = descriptor.atIndex(2)?.stringValue,
              let tabIdentifier = Int(rawTab), tabIdentifier > 0,
              let rawURL = descriptor.atIndex(3)?.stringValue, let url = URL(string: rawURL),
              isChatGPT(url),
              let active = descriptor.atIndex(4)?.stringValue else { return nil }
        return TabLocation(
            windowIdentifier: windowIdentifier,
            tabIdentifier: tabIdentifier,
            url: url,
            isSelected: Int(active) == tabIdentifier
        )
    }

    private func chrome() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first
    }

    private func chromeMatches(_ reference: ChromeVoiceTabReference) -> Bool {
        guard let application = chrome(),
              application.processIdentifier == reference.processIdentifier else { return false }
        if let trackedLaunchDate, let currentLaunchDate = application.launchDate {
            return trackedLaunchDate == currentLaunchDate
        }
        return true
    }

    private func isChatGPT(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "chatgpt.com"
    }

    private func waitForChromeFocus(
        _ reference: ChromeVoiceTabReference,
        cancellation: ChromeVoiceCancellation
    ) throws {
        // Chrome's activate event can return just before a Space/window switch
        // updates NSWorkspace. Allow that short handoff without reactivating it.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            try cancellation.check()
            guard chromeMatches(reference) else { throw ChromeVoiceError.targetChanged }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == reference.processIdentifier { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw ChromeVoiceError.targetChanged
    }

    private func waitForControls(
        _ reference: ChromeVoiceTabReference,
        starting: Bool,
        requireReloadReady: Bool = false,
        cancellation: ChromeVoiceCancellation
    ) throws -> Snapshot {
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        repeat {
            try cancellation.check()
            do {
                let current = try foregroundSnapshot(reference, cancellation: cancellation)
                let ready = starting
                    ? current.voiceUIActive && !current.connecting
                    : current.readyForVoice
                if ready, !requireReloadReady || current.reload.count == 1 {
                    return current
                }
            } catch ChromeVoiceError.accessibilityUnavailable {
                // Loading/navigating web areas can be temporarily unavailable.
            }
            try cancellation.check()
            Thread.sleep(forTimeInterval: Self.pollInterval)
        } while Date() < deadline
        throw starting ? ChromeVoiceError.startFailed : ChromeVoiceError.controlsUnavailable
    }

    private func waitForLaunchControls(
        _ reference: ChromeVoiceTabReference,
        isResuming: Bool,
        cancellation: ChromeVoiceCancellation
    ) throws -> Snapshot {
        do {
            return try waitForControls(reference, starting: false, cancellation: cancellation)
        } catch ChromeVoiceError.controlsUnavailable {
            guard isResuming else { throw ChromeVoiceError.controlsUnavailable }
            let stalled = try foregroundSnapshot(reference, cancellation: cancellation)
            if stalled.readyForVoice { return stalled }
            guard mayReloadForResume(stalled) else {
                throw ChromeVoiceError.controlsUnavailable
            }

            // Re-read the call/recording state and the native toolbar together.
            // Page buttons are excluded from the Reload candidates because the
            // Chrome traversal stops at each AXWebArea.
            let beforeReload = try foregroundSnapshot(reference, cancellation: cancellation)
            if beforeReload.readyForVoice { return beforeReload }
            guard mayReloadForResume(beforeReload) else {
                throw ChromeVoiceError.controlsUnavailable
            }
            guard beforeReload.reload.count == 1, let button = beforeReload.reload.first else {
                throw ChromeVoiceError.reloadUnavailable
            }
            _ = try verifySelected(reference, cancellation: cancellation)
            try cancellation.check()
            do {
                try press(button)
            } catch ChromeVoiceError.unsupportedPress {
                throw ChromeVoiceError.reloadUnavailable
            }

            retainedTarget = nil
            memory.observe(.unknown)
            try cancellation.check()
            Thread.sleep(forTimeInterval: Self.pollInterval)
            // This calls the ordinary readiness wait, so there is no recursive
            // reload. Chrome's Reload control must have returned from loading
            // before the new page's voice controls are accepted.
            return try waitForControls(
                reference,
                starting: false,
                requireReloadReady: true,
                cancellation: cancellation
            )
        }
    }

    private func mayReloadForResume(_ snapshot: Snapshot) -> Bool {
        ChromeVoiceReloadPolicy.shouldReload(
            isResuming: true,
            reloadAttempted: false,
            startButtonCount: snapshot.start.count,
            endButtonCount: snapshot.end.count,
            microphoneCount: snapshot.microphones.count,
            isRecording: snapshot.recording,
            isConnecting: snapshot.connecting
        )
    }

    private func foregroundSnapshot(
        _ reference: ChromeVoiceTabReference,
        cancellation: ChromeVoiceCancellation
    ) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw ChromeVoiceError.accessibilityDenied }
        let location = try verifySelected(reference, cancellation: cancellation)
        let application = AXUIElementCreateApplication(reference.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let window = elementValue(application, kAXFocusedWindowAttribute) else {
            throw ChromeVoiceError.accessibilityUnavailable
        }
        let chromeNodes = try walk(window, stopAtWebAreas: true, cancellation: cancellation)
        let areas = chromeNodes.filter { element in
            guard textValue(element, kAXRoleAttribute) == "AXWebArea",
                  let url = URL(string: textValue(element, kAXURLAttribute)) else { return false }
            return isChatGPT(url)
        }
        guard areas.count == 1, let area = areas.first else {
            throw ChromeVoiceError.accessibilityUnavailable
        }
        return try snapshot(
            window: window,
            area: area,
            chromeNodes: chromeNodes,
            location: location,
            cancellation: cancellation
        )
    }

    private func snapshot(
        window: AXUIElement,
        area: AXUIElement,
        chromeNodes: [AXUIElement],
        location: TabLocation,
        cancellation: ChromeVoiceCancellation?
    ) throws -> Snapshot {
        let nodes = try walk(area, cancellation: cancellation)
        let buttons = nodes.filter {
            textValue($0, kAXRoleAttribute) == kAXButtonRole && enabled($0)
        }
        let start = buttons.filter { matches($0, labels: Self.startLabels) }
        let end = buttons.filter { matches($0, labels: Self.endLabels) }
        guard start.count <= 1, end.count <= 1 else { throw ChromeVoiceError.ambiguousControls }
        let microphones = buttons.filter { matches($0, labels: Self.microphoneLabels) }
        let reload = chromeNodes.filter {
            textValue($0, kAXRoleAttribute) == kAXButtonRole && enabled($0)
                && matches($0, labels: Self.reloadLabels)
        }
        let tabs = chromeNodes.filter {
            textValue($0, kAXRoleAttribute) == kAXRadioButtonRole
                && textValue($0, kAXSubroleAttribute) == "AXTabButton"
                && (value($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
        }
        let selectedTab = tabs.count == 1 ? tabs.first : nil
        var metadata = [textValue(window, kAXTitleAttribute)]
        if let selectedTab {
            metadata += [textValue(selectedTab, kAXTitleAttribute), textValue(selectedTab, kAXDescriptionAttribute)]
        }
        let recording = metadata.contains {
            let text = $0.lowercased()
            return text.contains("麦克风正在录音") || text.contains("麥克風正在錄音")
                || text.contains("microphone is recording")
        }
        let connecting = nodes.contains { element in
            (names(element) + [textValue(element, kAXValueAttribute)]).contains {
                Self.connectingLabels.contains(normalized($0))
            }
        }
        return Snapshot(
            window: window,
            webArea: area,
            selectedTab: selectedTab,
            location: location,
            start: start,
            end: end,
            microphones: microphones,
            reload: reload,
            connecting: connecting,
            recording: recording
        )
    }

    private func press(_ button: AXUIElement) throws {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(button, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true,
              enabled(button),
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw ChromeVoiceError.unsupportedPress
        }
    }

    private func retain(_ snapshot: Snapshot, for reference: ChromeVoiceTabReference) {
        retainedTarget = RetainedTarget(reference: reference, snapshot: snapshot)
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.observeWithoutFocusing()
        }
        monitor = timer
        timer.resume()
    }

    private func observeWithoutFocusing() {
        guard let reference = memory.reference else { return }
        guard chromeMatches(reference) else {
            reset()
            return
        }
        guard AXIsProcessTrusted() else {
            memory.observe(.unknown)
            return
        }
        do {
            guard let location = try locate(reference, cancellation: nil) else {
                reset()
                return
            }
            guard let retainedTarget, retainedTarget.reference == reference,
                  retainedTarget.snapshot.location.windowIdentifier == location.windowIdentifier,
                  location.isSelected else {
                memory.observe(.unknown)
                return
            }
            let retained = retainedTarget.snapshot
            // Chrome can reuse a web-area object when the user switches tabs.
            // Only read it when the scripting ID still identifies the selected
            // owned tab in this window; no foreground/app activation is needed.
            let application = AXUIElementCreateApplication(reference.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 1)
            guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement],
                  windows.contains(where: { CFEqual($0, retained.window) }),
                  textValue(retained.webArea, kAXRoleAttribute) == "AXWebArea",
                  let areaURL = URL(string: textValue(retained.webArea, kAXURLAttribute)),
                  areaURL == location.url else {
                memory.observe(.unknown)
                return
            }
            let chromeNodes = try walk(retained.window, stopAtWebAreas: true)
            guard chromeNodes.contains(where: { CFEqual($0, retained.webArea) }) else {
                memory.observe(.unknown)
                return
            }
            let current = try snapshot(
                window: retained.window,
                area: retained.webArea,
                chromeNodes: chromeNodes,
                location: location,
                cancellation: nil
            )
            memory.observe(current.activity)
            retain(current, for: reference)
        } catch {
            // An unreadable background tab is not evidence that a call ended.
            memory.observe(.unknown)
        }
    }

    private func reset() {
        monitor?.cancel()
        monitor = nil
        memory.reset()
        retainedTarget = nil
        trackedLaunchDate = nil
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    private func textValue(_ element: AXUIElement, _ attribute: String) -> String {
        guard let result = value(element, attribute) else { return "" }
        if let text = result as? String { return text }
        if let url = result as? URL { return url.absoluteString }
        return ""
    }

    private func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else {
            return nil
        }
        return (result as! AXUIElement)
    }

    private func names(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXLabel"]
            .map { textValue(element, $0) }
            .filter { !$0.isEmpty }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ element: AXUIElement, labels: Set<String>) -> Bool {
        names(element).contains { labels.contains(normalized($0)) }
    }

    private func enabled(_ element: AXUIElement) -> Bool {
        (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true
    }

    private func walk(
        _ root: AXUIElement,
        stopAtWebAreas: Bool = false,
        cancellation: ChromeVoiceCancellation? = nil
    ) throws -> [AXUIElement] {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var result: [AXUIElement] = []
        var visited: Set<AXIdentity> = []
        while let (element, depth) = stack.popLast() {
            try cancellation?.check()
            guard visited.insert(AXIdentity(element: element)).inserted else { continue }
            guard result.count < 10_000, depth < 60 else {
                throw ChromeVoiceError.accessibilityUnavailable
            }
            let role = textValue(element, kAXRoleAttribute)
            guard !role.isEmpty else { throw ChromeVoiceError.accessibilityUnavailable }
            result.append(element)
            if stopAtWebAreas, role == "AXWebArea" { continue }
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return result
    }
}
