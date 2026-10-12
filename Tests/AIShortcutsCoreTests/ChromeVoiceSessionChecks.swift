import AIShortcutsCore
import CoreGraphics
import Foundation

private struct ChromeVoiceCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectChromeVoice(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw ChromeVoiceCheckFailure(description: message)
    }
}

func chromeVoiceSessionChecks() async throws {
    let visibleBounds = CGRect(x: -1_440, y: 25, width: 1_440, height: 900)
    try expectChromeVoice(
        ChromeVoiceTargetPolicy.matchesFocusedWindow(
            tabIsSelected: true, windowIsMinimized: false,
            scriptingBounds: visibleBounds, focusedBounds: visibleBounds
        ),
        "A focused, selected ChatGPT window must be accepted regardless of Chrome's scripting window order."
    )
    try expectChromeVoice(
        ChromeVoiceTargetPolicy.matchesFocusedWindow(
            tabIsSelected: true, windowIsMinimized: false,
            scriptingBounds: visibleBounds,
            focusedBounds: visibleBounds.offsetBy(dx: 1, dy: -1)
        ),
        "Small AX rounding differences must not reject the visible window."
    )
    let wrongWindows: [(Bool, Bool, CGRect)] = [
        (false, false, visibleBounds),
        (true, true, visibleBounds),
        (true, false, visibleBounds.offsetBy(dx: 200, dy: 0)),
        (true, false, .zero),
    ]
    for (selected, minimized, focusedBounds) in wrongWindows {
        try expectChromeVoice(
            !ChromeVoiceTargetPolicy.matchesFocusedWindow(
                tabIsSelected: selected, windowIsMinimized: minimized,
                scriptingBounds: visibleBounds, focusedBounds: focusedBounds
            ),
            "An unselected, minimized, or different window must never supply the voice button."
        )
    }
    let budget = ChromeVoiceLaunchBudget(now: 100)
    try expectChromeVoice(
        budget.remaining(now: 100) == 8 && budget.remaining(now: 109) == 0,
        "Voice startup must have a single eight-second monotonic budget."
    )
    try expectChromeVoice(
        budget.stageDeadline(duration: 3, now: 100) == 103
            && budget.stageDeadline(duration: 4, now: 106) == 108
            && budget.stageDeadline(duration: 3, now: 107) == 108,
        "Reload and voice-start waits must use only the remaining startup budget."
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let tab = ChromeVoiceTabReference(processIdentifier: 100, tabIdentifier: 42)

    var memory = ChromeVoiceSessionMemory()
    try expectChromeVoice(
        memory.reference == nil && memory.idleSince == nil
            && memory.idleTimeout == 1_800,
        "New Chrome voice memory must be empty with a 30-minute idle window."
    )
    let firstUse = memory.decision(
        referenceIsValid: true,
        activity: .active,
        now: start
    )
    try expectChromeVoice(
        firstUse == .createNewTab,
        "Without an owned tab, the shortcut must start a new tab."
    )
    memory.observe(.inactive, now: start)
    try expectChromeVoice(
        memory.idleSince == nil,
        "An observation without an owned tab must not start an idle timer."
    )

    memory.remember(tab, now: start)
    let loading = memory.decision(
        referenceIsValid: true,
        activity: .unknown,
        now: start.addingTimeInterval(3_600)
    )
    try expectChromeVoice(
        loading == .inspectTrackedTab && memory.reference == tab && memory.idleSince == nil,
        "Remembering a pending tab must not expire it before observing its voice state."
    )
    let retry = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(3_600)
    )
    try expectChromeVoice(
        retry == .resumeTrackedTab
            && memory.idleSince == start.addingTimeInterval(3_600),
        "An explicit retry after a failed voice start must reuse its pending tab."
    )

    memory.remember(tab, now: start)
    memory.observe(.inactive, now: start)
    memory.observe(.inactive, now: start.addingTimeInterval(300))
    try expectChromeVoice(
        memory.idleSince == start,
        "Repeated inactive observations must preserve the first idle timestamp."
    )
    let beforeExpiry = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(1_799)
    )
    let atExpiry = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(1_800)
    )
    try expectChromeVoice(
        beforeExpiry == .resumeTrackedTab && atExpiry == .createNewTab
            && memory.reference == tab && memory.idleSince == start,
        "An idle conversation must resume before 30 minutes and expire at the boundary without losing its reference."
    )

    memory.observe(.unknown, now: start.addingTimeInterval(1_900))
    let unreadableAfterExpiry = memory.decision(
        referenceIsValid: true,
        activity: .unknown,
        now: start.addingTimeInterval(2_000)
    )
    try expectChromeVoice(
        unreadableAfterExpiry == .inspectTrackedTab && memory.idleSince == start,
        "Unreadable Accessibility state must preserve elapsed idle time and require inspection."
    )
    let confirmedExpiry = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(2_001)
    )
    try expectChromeVoice(
        confirmedExpiry == .createNewTab,
        "Confirming inactivity after unknown state must use the original idle timestamp."
    )

    let stillActive = memory.decision(
        referenceIsValid: true,
        activity: .active,
        now: start.addingTimeInterval(7_200)
    )
    try expectChromeVoice(
        stillActive == .resumeTrackedTab && memory.reference == tab && memory.idleSince == nil,
        "A confirmed active call must override an expired idle decision."
    )
    // A muted call is still reported as active by the browser service.
    memory.observe(.active, now: start.addingTimeInterval(10_800))
    let longCall = memory.decision(
        referenceIsValid: true,
        activity: .active,
        now: start.addingTimeInterval(14_400)
    )
    try expectChromeVoice(
        longCall == .resumeTrackedTab && memory.idleSince == nil,
        "Long or muted active calls must remain eligible regardless of elapsed time."
    )
    let callEnded = start.addingTimeInterval(14_405)
    memory.observe(.inactive, now: callEnded)
    try expectChromeVoice(
        memory.idleSince == callEnded,
        "The idle window must begin when inactivity is observed after the call ends."
    )
    let resumeAfterCall = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: callEnded.addingTimeInterval(1_799)
    )
    try expectChromeVoice(
        resumeAfterCall == .resumeTrackedTab,
        "A long call must still receive a full idle window after it ends."
    )

    let invalidTab = memory.decision(
        referenceIsValid: false,
        activity: .active,
        now: callEnded
    )
    try expectChromeVoice(
        invalidTab == .createNewTab && memory.reference == nil && memory.idleSince == nil,
        "A closed or navigated-away tab must reset tracking even if cached voice state was active."
    )
    memory.remember(tab, now: start)
    let restartedProcess: Int32 = 101
    let chromeRestart = memory.decision(
        referenceIsValid: memory.reference?.processIdentifier == restartedProcess,
        activity: .unknown,
        now: start
    )
    try expectChromeVoice(
        chromeRestart == .createNewTab && memory.reference == nil,
        "Caller validation of a changed Chrome process must invalidate the remembered tab."
    )

    memory.remember(tab, now: start)
    memory.observe(.inactive, now: start)
    let replacement = ChromeVoiceTabReference(processIdentifier: 100, tabIdentifier: 99)
    memory.remember(replacement, now: start.addingTimeInterval(1_800))
    try expectChromeVoice(
        memory.reference == replacement && memory.idleSince == nil,
        "Remembering a replacement tab must discard the old idle timer."
    )
    memory.observe(.inactive, now: start)
    memory.reset()
    let afterReset = memory.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start
    )
    try expectChromeVoice(
        afterReset == .createNewTab && memory.reference == nil && memory.idleSince == nil,
        "Restart/reset must forget both the owned tab and its idle timestamp."
    )

    var shortWindow = ChromeVoiceSessionMemory(idleTimeout: 10)
    shortWindow.remember(tab, now: start)
    shortWindow.observe(.inactive, now: start)
    let injectedExpiry = shortWindow.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(10)
    )
    try expectChromeVoice(
        injectedExpiry == .createNewTab,
        "The injected clock and timeout must permit deterministic expiration checks."
    )

    try chromeVoiceReloadChecks(start: start, tab: tab)
}

private func chromeVoiceReloadChecks(start: Date, tab: ChromeVoiceTabReference) throws {
    func reloadAllowed(
        isResuming: Bool = true,
        reloadAttempted: Bool = false,
        startButtons: Int = 0,
        endButtons: Int = 0,
        microphones: Int = 0,
        recording: Bool = false,
        connecting: Bool = false
    ) -> Bool {
        ChromeVoiceReloadPolicy.shouldReload(
            isResuming: isResuming,
            reloadAttempted: reloadAttempted,
            startButtonCount: startButtons,
            endButtonCount: endButtons,
            microphoneCount: microphones,
            isRecording: recording,
            isConnecting: connecting
        )
    }

    try expectChromeVoice(
        reloadAllowed(),
        "A remembered tab with no voice controls may reload once after readiness times out."
    )
    let blockedRecoveries: [(String, Bool)] = [
        ("a fresh tab", reloadAllowed(isResuming: false)),
        ("a second reload attempt", reloadAllowed(reloadAttempted: true)),
        ("a start voice button", reloadAllowed(startButtons: 1)),
        ("an end voice button", reloadAllowed(endButtons: 1)),
        ("a microphone control", reloadAllowed(microphones: 1)),
        ("confirmed recording", reloadAllowed(recording: true)),
        ("voice connecting", reloadAllowed(connecting: true)),
        ("ambiguous start controls", reloadAllowed(startButtons: 2)),
        ("ambiguous end controls", reloadAllowed(endButtons: 2)),
        ("ambiguous microphone controls", reloadAllowed(microphones: 2)),
    ]
    for (reason, allowed) in blockedRecoveries {
        try expectChromeVoice(
            !allowed,
            "Voice reload recovery must not interrupt \(reason)."
        )
    }

    var recoveringSession = ChromeVoiceSessionMemory()
    recoveringSession.remember(tab, now: start)
    recoveringSession.observe(.inactive, now: start)
    recoveringSession.observe(.unknown, now: start.addingTimeInterval(1_000))
    let missingControls = recoveringSession.decision(
        referenceIsValid: true,
        activity: .unknown,
        now: start.addingTimeInterval(1_020)
    )
    try expectChromeVoice(
        missingControls == .inspectTrackedTab && reloadAllowed()
            && recoveringSession.reference == tab && recoveringSession.idleSince == start,
        "Reload recovery must retain the same owned tab and its observed inactivity window."
    )
    let recoveredControls = recoveringSession.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(1_040)
    )
    try expectChromeVoice(
        recoveredControls == .resumeTrackedTab && recoveringSession.reference == tab,
        "Restored voice controls must resume the remembered conversation within its idle window."
    )
    let expiredAfterRecovery = recoveringSession.decision(
        referenceIsValid: true,
        activity: .inactive,
        now: start.addingTimeInterval(1_800)
    )
    try expectChromeVoice(
        expiredAfterRecovery == .createNewTab,
        "Reloading a remembered tab must not restart an existing idle window."
    )
}
