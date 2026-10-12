import AppKit

/// A floating panel must be ordered out when its owner leaves it. AppKit's
/// default `hidesOnDeactivate` only conceals it temporarily, then restores it
/// behind the next shortcut when this menu-bar application activates again.
@MainActor
final class TransientPanelDismissal: NSObject {
    private weak var window: NSWindow?
    private let relatedWindows: () -> [NSWindow]
    private let onDismiss: () -> Void
    private let monitorsOtherApplications: Bool
    private var isWatching = false
    private var menuTrackingDepth = 0
    private var generation = 0

    // Event-monitor removal is thread-safe. These tokens are read outside the
    // main actor only during deinit, after their owner can no longer be used.
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    init(
        window: NSWindow,
        relatedWindows: @escaping () -> [NSWindow] = { [] },
        monitorsOtherApplications: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.window = window
        self.relatedWindows = relatedWindows
        self.monitorsOtherApplications = monitorsOtherApplications
        self.onDismiss = onDismiss
        super.init()
        (window as? NSPanel)?.hidesOnDeactivate = false
    }

    func start() {
        stop()
        isWatching = true
        let notifications = NotificationCenter.default
        notifications.addObserver(
            self, selector: #selector(applicationDeactivated),
            name: NSApplication.didResignActiveNotification, object: NSApp
        )
        notifications.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window
        )
        notifications.addObserver(
            self, selector: #selector(menuBeganTracking),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(menuEndedTracking),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        if monitorsOtherApplications {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
                self?.handleGlobalMouseDown()
            }
        }
    }

    func stop() {
        isWatching = false
        generation &+= 1
        menuTrackingDepth = 0
        NotificationCenter.default.removeObserver(self)
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    /// Key changes are deferred until AppKit has installed the new key
    /// window. Native popup menus can briefly leave no key window at all;
    /// that is not a click away from the panel.
    func handleResignKey() {
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expectedGeneration,
                  self.isWatching, self.window?.isVisible == true,
                  self.menuTrackingDepth == 0
            else { return }
            if !NSApp.isActive {
                self.dismiss()
            } else if let keyWindow = NSApp.keyWindow, !self.contains(keyWindow) {
                self.dismiss()
            }
        }
    }

    /// Internal so offscreen native checks can deliver the exact event path
    /// without posting mouse clicks to the user's desktop.
    func handleMouseDown(_ event: NSEvent) {
        guard isWatching, window?.isVisible == true, menuTrackingDepth == 0,
              let eventWindow = event.window, !contains(eventWindow)
        else { return }
        dismiss()
    }

    private func handleGlobalMouseDown() {
        guard isWatching, let window, window.isVisible, menuTrackingDepth == 0 else { return }
        let point = NSEvent.mouseLocation
        let ownedWindows = [window] + relatedWindows() + (window.childWindows ?? [])
        guard !ownedWindows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
        dismiss()
    }

    private func contains(_ candidate: NSWindow) -> Bool {
        guard let window else { return false }
        let ownedWindows = [window] + relatedWindows()
        var ancestor: NSWindow? = candidate
        while let current = ancestor {
            if ownedWindows.contains(where: { $0 === current }) { return true }
            ancestor = current.parent ?? current.sheetParent
        }
        return false
    }

    private func dismiss() {
        guard isWatching else { return }
        stop()
        onDismiss()
    }

    @objc private func applicationDeactivated(_ notification: Notification) {
        // Unlike isVisible, isWatching remains reliable even if AppKit has
        // already hidden a panel during its deactivation notification.
        dismiss()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        handleResignKey()
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        menuTrackingDepth += 1
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }
}
