import AIShortcutsCore
import AppKit
import ApplicationServices
import Foundation

private struct VoiceCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VoiceCheckFailure(description: message) }
}

private func receipt(
    url: String = "https://chatgpt.com/", selected: String = "42", minimized: Bool = false
) -> NSAppleEventDescriptor {
    let descriptor = NSAppleEventDescriptor.list()
    descriptor.insert(NSAppleEventDescriptor(string: "100"), at: 1)
    descriptor.insert(NSAppleEventDescriptor(string: "42"), at: 2)
    descriptor.insert(NSAppleEventDescriptor(string: url), at: 3)
    descriptor.insert(NSAppleEventDescriptor(string: selected), at: 4)
    descriptor.insert(NSAppleEventDescriptor(boolean: minimized), at: 5)
    let bounds = NSAppleEventDescriptor.list()
    for (index, edge) in [Int32(-1440), 25, 0, 925].enumerated() {
        bounds.insert(NSAppleEventDescriptor(int32: edge), at: index + 1)
    }
    descriptor.insert(bounds, at: 6)
    return descriptor
}

@main
struct VoiceNativeChecks {
    static func main() {
        do { try run() }
        catch {
            print("FAIL native Chrome voice checks: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let visible = try unwrap(ChromeVoiceTabLocation(receipt()), "Valid Chrome receipt was rejected")
        try check(visible.isSelected && !visible.isMinimized && visible.tabIdentifier == 42,
                  "Selected visible tab state was lost")
        try check(visible.bounds == CGRect(x: -1440, y: 25, width: 1440, height: 900),
                  "Chrome's top-left bounds did not match AX coordinates on a secondary display")
        try check(ChromeVoiceTabLocation(receipt(selected: "43"))?.isSelected == false,
                  "A tab switch was treated as the owned selection")
        try check(ChromeVoiceTabLocation(receipt(minimized: true))?.isMinimized == true,
                  "Minimized window state was lost")
        for expected in [false, true] {
            var scriptError: NSDictionary?
            let nativeBoolean = NSAppleScript(source: "return \(expected)")!.executeAndReturnError(&scriptError)
            let nativeReceipt = receipt()
            nativeReceipt.insert(nativeBoolean, at: 5)
            try check(scriptError == nil && ChromeVoiceTabLocation(nativeReceipt)?.isMinimized == expected,
                      "AppleScript's native true/false descriptor was rejected")
        }
        for url in ["https://github.com/", "https://chatgpt.com.attacker.invalid/", "http://chatgpt.com/"] {
            try check(ChromeVoiceTabLocation(receipt(url: url)) == nil, "Non-ChatGPT URL was accepted")
        }
        let malformed = receipt()
        malformed.remove(at: 6)
        try check(ChromeVoiceTabLocation(malformed) == nil, "Missing window bounds were accepted")
        let malformedBoolean = receipt()
        malformedBoolean.insert(NSAppleEventDescriptor(string: "false"), at: 5)
        try check(ChromeVoiceTabLocation(malformedBoolean) == nil, "Malformed minimized state was accepted")
        let home = URL(string: "https://chatgpt.com/")!
        try check(ChromeVoiceTabLocation.samePage(home, URL(string: "https://chatgpt.com#composer")!),
                  "Harmless slash/fragment differences rejected the same page")
        try check(!ChromeVoiceTabLocation.samePage(home, URL(string: "https://chatgpt.com/c/other")!),
                  "A stale web area from another conversation was accepted")
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil {
            let script = try unwrap(NSAppleScript(source: ChromeVoiceScripts.locate(tabIdentifier: 42)),
                                    "Could not create the production lookup script")
            var error: NSDictionary?
            try check(script.compileAndReturnError(&error), "Production Chrome lookup script did not compile: \(String(describing: error))")
        }
        if CommandLine.arguments.contains("--inspect") { try inspectChrome() }
        print("All native Chrome voice checks passed.")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VoiceCheckFailure(description: message) }
        return value
    }

    /// Read-only integration check: never activates Chrome or starts a microphone.
    private static func inspectChrome() throws {
        let query = """
        with timeout of 2 seconds
            tell application id "com.google.Chrome"
                if not running then return ""
                repeat with candidateWindow in windows
                    if mode of candidateWindow is "normal" then
                        repeat with candidateTab in tabs of candidateWindow
                            if URL of candidateTab starts with "https://chatgpt.com/" then
                                return id of candidateTab as text
                            end if
                        end repeat
                    end if
                end repeat
                return ""
            end tell
        end timeout
        """
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: query)!.executeAndReturnError(&error)
        try check(error == nil, "Chrome read-only query failed: \(String(describing: error))")
        let tabIdentifier = try unwrap(Int(descriptor.stringValue ?? ""), "No ChatGPT tab to inspect")
        let started = ProcessInfo.processInfo.systemUptime
        let result = NSAppleScript(source: ChromeVoiceScripts.locate(tabIdentifier: tabIdentifier))!
            .executeAndReturnError(&error)
        try check(error == nil, "Production Chrome lookup failed: \(String(describing: error))")
        let location = try unwrap(ChromeVoiceTabLocation(result), "Production lookup rejected the real ChatGPT tab")
        try check(location.tabIdentifier == tabIdentifier,
                  "Production lookup did not identify the real ChatGPT tab")
        print("PASS live read-only ChatGPT tab lookup (\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms)")
        guard AXIsProcessTrusted(), !location.isMinimized else { return }
        let chrome = try unwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first,
                                "Chrome process disappeared during inspection")
        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var rawWindows: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
                  "Chrome's native windows were unreadable")
        let windows = try unwrap(rawWindows as? [AXUIElement], "Chrome returned no native windows")
        let matches = windows.filter { window in
            var rawPosition: CFTypeRef?
            var rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let rawPosition, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
                  AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return false }
            return ChromeVoiceTargetPolicy.matchesFocusedWindow(
                tabIsSelected: true, windowIsMinimized: false,
                scriptingBounds: location.bounds, focusedBounds: CGRect(origin: position, size: size)
            )
        }
        try check(matches.count == 1, "The real Chrome receipt did not uniquely match its native window")
        print("PASS live read-only native Chrome window matching")
    }
}
