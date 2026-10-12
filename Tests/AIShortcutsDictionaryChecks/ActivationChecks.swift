import AIShortcutsCore
import AppKit
import Foundation

private struct DictionaryActivationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireActivation(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw DictionaryActivationCheckFailure(description: message)
    }
}

private final class ActivationTransport: HTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let pieces = request.url!.path.split(separator: "/")
        let word = String(pieces.last ?? "activation")
        let language = String(pieces.dropLast().last ?? "en")
        let object: [String: Any] = [
            "word": word,
            "entries": [[
                "language": ["code": language, "name": language],
                "partOfSpeech": "noun",
                "senses": [["definition": "activation fixture"]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

@MainActor
private final class ActivationSelectionState {
    var calls = 0
    var allow = false
}

@MainActor
private func waitForActivation(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw DictionaryActivationCheckFailure(description: "Timed out waiting for first activation")
}

/// Exercises the event timing protected by press dispatch when a Carbon
/// release is delayed or missing. The dictionary must begin on its first
/// press, while all other shortcuts retain their existing
/// prepare-on-press/release-dispatch ordering.
@MainActor
func dictionaryActivationChecks() async throws {
    var dispatchState = HotKeyDispatchState()
    let firstPress = dispatchState.pressed(.dictionary)
    try requireActivation(firstPress.prepare, "Dictionary press did not prepare capture")
    try requireActivation(firstPress.dispatch, "Dictionary action waited for a release event")
    let repeatedPress = dispatchState.pressed(.dictionary)
    try requireActivation(!repeatedPress.prepare && !repeatedPress.dispatch,
                          "A held dictionary key generated a duplicate action")
    try requireActivation(!dispatchState.released(.dictionary),
                          "Dictionary release dispatched a second action")
    let secondPress = dispatchState.pressed(.dictionary)
    try requireActivation(secondPress.dispatch,
                          "Dictionary did not arm again after its key was released")
    var missingReleaseState = HotKeyDispatchState()
    _ = missingReleaseState.pressed(.dictionary)
    missingReleaseState.reset()
    try requireActivation(missingReleaseState.pressed(.dictionary).dispatch,
                          "A missed release could not recover on the next chord")

    var otherState = HotKeyDispatchState()
    let otherPress = otherState.pressed(.translate)
    try requireActivation(otherPress.prepare && !otherPress.dispatch,
                          "An existing shortcut changed to press dispatch")
    try requireActivation(otherState.released(.translate),
                          "An existing shortcut lost release dispatch")

    var workInspectionRan = false
    try requireActivation(
        DictionaryActivationPolicy.shouldSkipOnboarding(
            consumePanelActivation: { true },
            hasActiveWork: {
                workInspectionRan = true
                return false
            }
        ) && !workInspectionRan,
        "A reentrant panel activation inspected onboarding before its pending token"
    )
    try requireActivation(
        DictionaryActivationPolicy.shouldSkipOnboarding(
            consumePanelActivation: { false },
            hasActiveWork: { true }
        ),
        "Active dictionary work did not suppress onboarding"
    )
    try requireActivation(
        !DictionaryActivationPolicy.shouldSkipOnboarding(
            consumePanelActivation: { false },
            hasActiveWork: { false }
        ),
        "Idle dictionary state incorrectly suppressed onboarding"
    )
    try requireActivation(
        DictionaryTogglePolicy.disposition(
            panelVisible: true,
            panelIsKey: false,
            appIsActive: false,
            captureInFlight: false
        ) == .activateVisiblePanel,
        "The first press closed a visible inactive dictionary panel"
    )
    try requireActivation(
        DictionaryTogglePolicy.disposition(
            panelVisible: true,
            panelIsKey: false,
            appIsActive: true,
            captureInFlight: false
        ) == .activateVisiblePanel,
        "The first press closed a dictionary panel behind another app window"
    )
    try requireActivation(
        DictionaryTogglePolicy.disposition(
            panelVisible: true,
            panelIsKey: true,
            appIsActive: true,
            captureInFlight: false
        ) == .dismissVisiblePanel,
        "The focused dictionary panel lost its shortcut dismissal"
    )
    try requireActivation(
        DictionaryTogglePolicy.disposition(
            panelVisible: false,
            panelIsKey: false,
            appIsActive: false,
            captureInFlight: true
        ) == .ignorePendingCapture,
        "A duplicate press restarted pending dictionary capture"
    )

    let defaultsName = "AIShortcuts.DictionaryActivationChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    let historyStore = DictionaryHistoryStore(fileURL: nil)
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictionary-activation-\(UUID().uuidString)")
    let selectionState = ActivationSelectionState()
    let capture = DictionaryCoordinator.CaptureDependencies(
        accessibilityTrusted: { true },
        selectedText: { @MainActor in
            selectionState.calls += 1
            while !selectionState.allow {
                if Task.isCancelled {
                    return nil
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return "first press"
        }
    )
    let coordinator = DictionaryCoordinator(
        stateStore: AppStateStore(defaults: defaults),
        selectionService: SelectionService(),
        panel: panel,
        lookupService: DictionaryLookupService(
            transport: ActivationTransport(),
            cacheDirectoryURL: cacheDirectory
        ),
        historyStore: historyStore,
        captureDependencies: capture
    )
    defer {
        selectionState.allow = true
        coordinator.releaseResources()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    coordinator.start()
    try await waitForActivation { selectionState.calls == 1 }
    // The panel is not visible while selection is pending. A duplicate
    // activation must not restart and cancel this first capture.
    coordinator.toggle()
    selectionState.allow = true
    try await waitForActivation { panel.isVisible }
    try requireActivation(selectionState.calls == 1,
                          "A repeated activation restarted the first capture")
    try requireActivation(coordinator.hasActiveWork,
                          "Dictionary activation lost its active lifecycle")
    try requireActivation(coordinator.consumePanelActivation(),
                          "Panel activation was not consumed by the dictionary lifecycle")
    try requireActivation(!coordinator.consumePanelActivation(),
                          "Panel activation was consumed more than once")
    print("PASS first dictionary press dispatch, capture activation, and release gating")
}
