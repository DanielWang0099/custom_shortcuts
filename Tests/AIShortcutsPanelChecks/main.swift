import AIShortcutsCore
import AppKit
import Foundation
import WebKit

private struct PanelCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw PanelCheckFailure(description: message) }
}

private final class FixturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private func fixturePanel() -> NSPanel {
    let panel = FixturePanel(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 240),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.orderFront(nil)
    return panel
}

@MainActor
private func click(in window: NSWindow) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { throw PanelCheckFailure(description: "Cannot construct offscreen click") }
    return event
}

@MainActor
private func savePreview(_ window: NSWindow, named name: String) throws {
    guard let index = CommandLine.arguments.firstIndex(of: "--previews"),
          CommandLine.arguments.indices.contains(index + 1), let view = window.contentView
    else { return }
    let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Let WebKit settle without ordering a window onto any visible monitor.
    let deadline = Date().addingTimeInterval(2)
    let webView = view.subviews.compactMap { $0 as? WKWebView }.first
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while webView?.isLoading == true && Date() < deadline
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw PanelCheckFailure(description: "Cannot render Explain preview")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw PanelCheckFailure(description: "Cannot encode Explain preview")
    }
    try png.write(to: root.appendingPathComponent("\(name).png"))
}

@MainActor
private func dismissalChecks() throws {
    let panel = fixturePanel()
    let child = fixturePanel()
    let popover = fixturePanel()
    let other = fixturePanel()
    panel.addChildWindow(child, ordered: .above)
    defer {
        panel.removeChildWindow(child)
        for window in [panel, child, popover, other] { window.orderOut(nil) }
    }
    var dismissals = 0
    let dismissal = TransientPanelDismissal(window: panel, relatedWindows: { [popover] }) {
        dismissals += 1
        panel.orderOut(nil)
    }
    dismissal.start()
    try require(!panel.hidesOnDeactivate, "Transient panel still uses temporary app hiding")
    dismissal.handleMouseDown(try click(in: panel))
    dismissal.handleMouseDown(try click(in: child))
    dismissal.handleMouseDown(try click(in: popover))
    try require(dismissals == 0 && panel.isVisible, "Owned child/popover click dismissed its parent")

    let menu = NSMenu(title: "Fixture popup")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    dismissal.handleMouseDown(try click(in: other))
    try require(dismissals == 0, "Native menu tracking dismissed its parent")
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    dismissal.handleMouseDown(try click(in: other))
    try require(dismissals == 1 && !panel.isVisible, "Clicking another app window did not order out the panel")
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try require(!panel.isVisible, "Dismissed panel reappeared on later shortcut activation")

    panel.orderFront(nil)
    dismissal.start()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try require(dismissals == 2 && !panel.isVisible, "Application deactivation only hid the panel temporarily")
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try require(dismissals == 2, "A stopped dismissal observer fired twice")

    panel.orderFront(nil)
    dismissal.start()
    dismissal.stop()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try require(dismissals == 2 && panel.isVisible, "Stopped watcher still dismissed a new presentation")
    print("PASS outside-click dismissal, owned windows/menus, deactivation, and explicit reopen")
}

@MainActor
private func explainPlacementChecks() throws {
    var now: TimeInterval = 0
    let left = ExplanationPanelScreenGeometry(
        frame: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 900),
        visibleFrame: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 860)
    )
    let right = ExplanationPanelScreenGeometry(
        frame: NSRect(x: -18_800, y: -20_000, width: 1_000, height: 800),
        visibleFrame: NSRect(x: -18_800, y: -20_000, width: 1_000, height: 760)
    )
    var screens = [left, right]
    var pointer = NSPoint(x: left.frame.midX, y: left.frame.midY)
    let controller = ExplanationPanelController(
        placementClock: { now }, screenGeometryProvider: { screens },
        pointerLocationProvider: { pointer }, isOffscreenTest: true
    )
    defer { controller.releaseResources() }
    func show() {
        controller.show(
            exchanges: [ExplanationExchange(
                highlightedText: "", request: "Explain this in simple terms.",
                explanation: "A dictionary helps you look up a word. Translation helps you read a complete sentence."
            )],
            hasHiddenSelection: false, isLoading: false, onSubmit: { _, _ in }
        )
    }
    func centered(_ frame: NSRect, in screen: ExplanationPanelScreenGeometry) -> Bool {
        abs(frame.midX - screen.visibleFrame.midX) < 0.5
            && abs(frame.midY - screen.visibleFrame.midY) < 0.5
    }
    func move(_ window: NSWindow, origin: NSPoint) {
        controller.windowWillMove(Notification(name: NSWindow.willMoveNotification, object: window))
        window.setFrameOrigin(origin)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        controller.finishPanelWindowDrag()
    }

    show()
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.accessibilityLabel() == "Explain" })
    else { throw PanelCheckFailure(description: "Explain offscreen panel is missing") }
    try require(centered(window.frame, in: left), "New Explain session did not center on the pointer's screen")
    try savePreview(window, named: "explain-default")
    now = 10
    move(window, origin: NSPoint(x: left.visibleFrame.minX + 60, y: left.visibleFrame.minY + 90))
    let moved = window.frame
    controller.dismiss()
    pointer = NSPoint(x: right.frame.midX, y: right.frame.midY)
    now = 609
    show()
    try require(window.frame == moved, "Explain forgot its moved position within the ten-minute session")
    controller.setLoading(request: "Question", imageCount: 0)
    controller.complete(with: [])
    controller.showError("Retry")
    try require(window.frame == moved, "Loading/answer/error updates moved the Explain window")
    controller.dismiss()
    now = 1_209
    show()
    try require(centered(window.frame, in: right), "Expired Explain session did not center on the pointer's screen")

    // A programmatic move does not start a manually placed session.
    window.setFrameOrigin(NSPoint(x: right.visibleFrame.minX + 20, y: right.visibleFrame.minY + 20))
    now = 1_210
    show()
    try require(centered(window.frame, in: right), "Programmatic frame updates were remembered as user dragging")

    now = 1_220
    move(window, origin: NSPoint(x: right.visibleFrame.maxX - 630, y: right.visibleFrame.maxY - 400))
    let smaller = ExplanationPanelScreenGeometry(
        frame: NSRect(x: -20_000, y: -20_000, width: 560, height: 500),
        visibleFrame: NSRect(x: -20_000, y: -20_000, width: 560, height: 460)
    )
    screens = [smaller]
    pointer = NSPoint(x: smaller.frame.midX, y: smaller.frame.midY)
    now = 1_221
    show()
    try require(smaller.visibleFrame.insetBy(dx: 15, dy: 15).contains(window.frame),
                "Explain moved placement escaped a changed/smaller screen")
    try savePreview(window, named: "explain-smaller-screen")

    // Updates arriving after idle must not prolong the placement session.
    controller.complete(with: [])
    controller.dismiss()
    let hiddenFrame = window.frame
    controller.showError("Late failure")
    controller.complete(with: [])
    try require(!window.isVisible && window.frame == hiddenFrame,
                "Late Explain completion/error reopened or moved a dismissed panel")
    screens = [left, right]
    pointer = NSPoint(x: left.frame.midX, y: left.frame.midY)
    now = 1_821
    show()
    try require(centered(window.frame, in: left), "Asynchronous completion prolonged Explain placement memory")
    print("PASS Explain moved placement, ten-minute expiry, async stability, and screen clamping")
}

@MainActor
private func explainActivityChecks() throws {
    var session = ExplanationPanelPlacementSession()
    let firstScreen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    let nextScreen = NSRect(x: 1_000, y: 0, width: 1_000, height: 800)
    session.beginOperation(at: 0, activeScreenFrame: firstScreen)
    session.recordUserMove(at: 1, screenFrame: firstScreen)
    session.recordHumanActivity(at: 500)
    session.beginOperation(at: 1_099, activeScreenFrame: nextScreen)
    try require(session.isUserMoved && session.preferredScreenFrame == firstScreen,
                "Human interaction did not keep the active Explain placement session")
    session.recordHumanActivity(at: 1_699)
    session.beginOperation(at: 1_700, activeScreenFrame: nextScreen)
    try require(!session.isUserMoved && session.preferredScreenFrame == nextScreen,
                "First input after an idle expiry revived stale placement")
    session.recordUserMove(at: 1_701, screenFrame: nextScreen)
    session.beginOperation(at: 2_300, activeScreenFrame: firstScreen)
    try require(session.isUserMoved, "Explain placement expired before ten minutes")
    session.beginOperation(at: 2_900, activeScreenFrame: firstScreen)
    try require(!session.isUserMoved, "Explain placement did not expire at ten minutes")
    print("PASS Explain activity clock and exact session boundary")
}

@MainActor
private func explainAttachmentChecks() throws {
    let screen = ExplanationPanelScreenGeometry(
        frame: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 900),
        visibleFrame: NSRect(x: -20_000, y: -20_000, width: 1_200, height: 860))
    var geometry = screen
    let controller = ExplanationPanelController(placementClock: { 0 }, screenGeometryProvider: { [geometry] },
        pointerLocationProvider: { NSPoint(x: geometry.frame.midX, y: geometry.frame.midY) }, isOffscreenTest: true)
    defer { controller.releaseResources() }
    var submitted: [Data] = []
    controller.show(exchanges: [], hasHiddenSelection: false, isLoading: false,
                    onSubmit: { _, images in submitted = images })
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.accessibilityLabel() == "Explain" }),
          let content = window.contentView else { throw PanelCheckFailure(description: "Missing attachment window") }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func button(_ title: String) throws -> NSButton {
        guard let result = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == title })
        else { throw PanelCheckFailure(description: "Missing \(title)") }
        return result
    }
    let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
        NSColor.darkGray.setFill(); rect.fill()
        ("Image to explain\n筛选资料" as NSString).draw(at: NSPoint(x: 12, y: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white])
        return true
    }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    try require(pasteboard.writeObjects([image]), "Cannot create image paste fixture")
    let copiedChangeCount = pasteboard.changeCount
    controller.attachImages(from: pasteboard)
    try require(pasteboard.changeCount == copiedChangeCount, "Attaching an image changed the pasteboard")
    try require(try button("Send").isEnabled, "Image-only Explain submission was unavailable")
    try savePreview(window, named: "explain-image-attached")
    for _ in 0..<4 { controller.attachImages(from: pasteboard) }
    let strip = descendants(content).first { $0.accessibilityLabel() == "Image attachments" }!
    try require(strip.subviews.count == 4 && !(try button("Attach images").isEnabled), "Attachment bound was not enforced")
    geometry = ExplanationPanelScreenGeometry(frame: NSRect(x: -20_000, y: -20_000, width: 380, height: 500),
        visibleFrame: NSRect(x: -20_000, y: -20_000, width: 380, height: 460))
    controller.show(exchanges: [], hasHiddenSelection: false, isLoading: false,
                    onSubmit: { _, images in submitted = images })
    try require(strip.subviews.allSatisfy { strip.bounds.contains($0.frame) }, "Image previews overflowed a narrow Explain panel")
    try savePreview(window, named: "explain-four-images-narrow")
    let remove = try button("Remove image 2")
    _ = NSApp.sendAction(remove.action!, to: remove.target, from: remove)
    try require(strip.subviews.count == 3 && (try button("Attach images").isEnabled), "Removing an attachment did not restore capacity")
    let send = try button("Send")
    _ = NSApp.sendAction(send.action!, to: send.target, from: send)
    try require(submitted.count == 3 && submitted.allSatisfy { NSImage(data: $0) != nil }, "Image-only request did not contain valid PNGs")
    controller.setLoading(request: "", imageCount: 3)
    controller.attachImages(from: pasteboard)
    try require(strip.isHidden && !(try button("Attach images").isEnabled), "Loading accepted another attachment")
    controller.showError("Retry", retryImagePNGs: submitted)
    try require(strip.subviews.count == 3 && !strip.isHidden, "Retry lost image attachments")
    controller.resetDraft()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("explain-images-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("screenshot.png")
    try submitted[0].write(to: file)
    pasteboard.clearContents()
    try require(pasteboard.writeObjects([file as NSURL]), "Cannot create file attachment fixture")
    controller.attachImages(from: pasteboard)
    try require(strip.subviews.count == 1, "Image file attachment failed")
    print("PASS Explain image/file attachments, previews, bounds, removal, submit, loading, and retry")
}

@main
@MainActor
struct PanelChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            try dismissalChecks()
            try explainActivityChecks()
            try explainPlacementChecks()
            try explainAttachmentChecks()
            print("All native panel checks passed.")
        } catch {
            print("FAIL native panels: \(error)")
            exit(EXIT_FAILURE)
        }
    }
}
