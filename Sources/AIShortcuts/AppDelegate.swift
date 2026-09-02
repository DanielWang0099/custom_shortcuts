import AppKit
import ApplicationServices
import AIShortcutsCore
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: AppConfiguration.bundleIdentifier,
        category: "runtime"
    )
    private let stateStore = AppStateStore()
    private let keychainStore = KeychainStore()
    private let selectionService = SelectionService()
    private let screenshotService = ScreenshotService()
    private let finderService = FinderSelectionService()
    private let hud = HUDController()
    private let apiClient = ResponsesAPIClient()
    private let explanationPanel = ExplanationPanelController()
    private let inputLockPanel = InputLockPanelController()
    private let insertPanel = InsertPanelController()
    private let insertLibrary = InsertLibraryStore()
    private let shortcutGuide = ShortcutGuideWindowController()
    private let inputLockIndicator = InputLockIndicatorController()
    private let clipboardQueueIndicator = ClipboardQueueIndicatorController()

    private var fullBudget: DailyBudgetLedger
    private var hotKeyManager: HotKeyManager?
    private var promptPanel: PromptPanelController?
    private var singleInstanceLock: SingleInstanceLock?
    private var apiKey: String?
    private var isBusy = false
    private var currentAction: AIShortcutAction?
    private var activeTask: Task<Void, Never>?
    private var operationTimeout: DispatchWorkItem?
    private var operationGeneration = 0
    private var explanationMemory = ExplanationConversationMemory()
    private var pendingExplanationSelection: SelectionSnapshot?
    private var explanationRequestInFlight = false
    private var pendingExplanationRequest: String?
    private var pendingExplanationImagePNGs: [Data] = []
    private var pendingExplanationHasHiddenSelection = false
    private var lastAPIStatus = "Not used"
    private var finderAutomationAuthorization: FinderAutomationAuthorization = .unknown
    private var ignoreInputLockHotKeyUntil = Date.distantPast
    private var insertTargetApplication: NSRunningApplication?
    private var isShowingEnablementDialog = false
    private var apiKeyLoadAttempted = false
    private var accessibilityRequestIssuedThisRun = false
    private var screenRecordingRequestIssuedThisRun = false
    private lazy var inputLockService = InputLockService { [weak self] in
        Task { @MainActor [weak self] in
            self?.deactivateInputLock(showFeedback: true)
        }
    }
    private lazy var clipboardQueueService = ClipboardQueueService { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handleClipboardQueueEvent(event)
        }
    }

    private lazy var statusMenu = StatusMenuController { [weak self] in
        self?.menuSnapshot() ?? StatusMenuSnapshot(
            busy: false,
            enabled: false,
            keyReady: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            finderAutomationAuthorization: .unknown,
            fullBudgetRemaining: 0,
            lastAPIStatus: "Unavailable",
            currentAction: nil,
            enabledShortcutActions: Set(AIShortcutAction.allCases)
        )
    }

    override init() {
        fullBudget = DailyBudgetLedger(
            limit: AppConstants.fullDailyBudgetLimit,
            state: stateStore.loadFullBudgetState()
        )
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lock = SingleInstanceLock() else {
            logger.notice("A second process exited because AI Shortcuts is already running.")
            NSApp.terminate(nil)
            return
        }
        singleInstanceLock = lock

        configureMenuActions()
        _ = statusMenu

        do {
            hotKeyManager = try HotKeyManager(
                enabledActions: stateStore.enabledShortcutActions
            ) { [weak self] action in
                self?.handle(action)
            }
        } catch {
            hud.showError(error.localizedDescription)
            logger.error("Global shortcut registration failed.")
        }

        normalizeAndSaveBudgets()
        refreshFinderAutomationAuthorization()
        DispatchQueue.main.async { [weak self] in
            self?.continueOnboarding()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        continueOnboarding()
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputLockService.deactivate()
        inputLockIndicator.dismiss()
        clipboardQueueService.deactivate(notify: false)
        clipboardQueueIndicator.dismiss()
    }

    private func configureMenuActions() {
        statusMenu.onEnable = { [weak self] in
            self?.continueOnboarding(userInitiated: true)
        }
        statusMenu.onOpenDataSettings = {
            NSWorkspace.shared.open(AppConfiguration.dataSharingSettingsURL)
        }
        statusMenu.onReloadKey = { [weak self] in
            self?.loadOrImportAPIKey(showFeedback: true, forceImport: true)
        }
        statusMenu.onOpenAccessibilitySettings = { [weak self] in
            self?.requestAccessibilityPermission(openSettings: true)
        }
        statusMenu.onOpenScreenRecordingSettings = { [weak self] in
            self?.requestScreenRecordingPermission(openSettings: true)
        }
        statusMenu.onRequestFinderAutomation = { [weak self] in
            self?.requestFinderAutomationPermission()
        }
        statusMenu.onCancelOperation = { [weak self] in
            self?.cancelCurrentOperation(showFeedback: true)
        }
        statusMenu.onOpenShortcutGuide = { [weak self] in
            self?.shortcutGuide.show()
        }
        statusMenu.onToggleShortcut = { [weak self] action, enabled in
            self?.setShortcut(action, enabled: enabled)
        }
        statusMenu.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func menuSnapshot() -> StatusMenuSnapshot {
        normalizeAndSaveBudgets()
        return StatusMenuSnapshot(
            busy: isBusy,
            enabled: stateStore.dataSharingAcknowledged,
            keyReady: apiKey != nil,
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            finderAutomationAuthorization: finderAutomationAuthorization,
            fullBudgetRemaining: fullBudget.remaining,
            lastAPIStatus: lastAPIStatus,
            currentAction: currentAction?.displayName,
            enabledShortcutActions: stateStore.enabledShortcutActions
        )
    }

    private func showEnablementDialog() {
        guard !isShowingEnablementDialog else {
            return
        }
        isShowingEnablementDialog = true
        defer { isShowingEnablementDialog = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Enable AI Shortcuts"
        alert.informativeText = """
        What happens
        Selected text, cropped screenshots, images pasted into Explain, and Insert key labels used for ambiguous lookup 
        are sent to OpenAI with the API key from japanese-practice. Saved Insert values stay local and are never sent.

        Before continuing
        To use complimentary data-sharing tokens, enroll this key's project and enable input/output sharing in the \
        OpenAI dashboard. Every shortcut uses GPT-5.4 and shares a 1,000,000-token local UTC-day guard. The app cannot \
        see usage from other apps.

        Privacy and billing
        OpenAI may bill requests when eligibility or complimentary quota is unavailable. Do not send sensitive, \
        confidential, or proprietary content. Choose “I Confirm” only after the dashboard says this project is enrolled.
        """
        alert.addButton(withTitle: "I Confirm")
        alert.addButton(withTitle: "Open Data Settings")
        alert.addButton(withTitle: "Not Now")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            stateStore.dataSharingAcknowledged = true
            loadOrImportAPIKey(showFeedback: false)
            hud.showSuccess()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(AppConfiguration.dataSharingSettingsURL)
        default:
            break
        }
    }

    private func continueOnboarding(userInitiated: Bool = false) {
        guard !isShowingEnablementDialog else {
            return
        }
        if !stateStore.permissionsRequested {
            stateStore.permissionsRequested = true
        }
        guard AXIsProcessTrusted() else {
            if !accessibilityRequestIssuedThisRun || userInitiated {
                requestAccessibilityPermission(openSettings: userInitiated)
            }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if !screenRecordingRequestIssuedThisRun || userInitiated {
                requestScreenRecordingPermission(openSettings: userInitiated)
            }
            return
        }

        if !stateStore.dataSharingAcknowledged {
            showEnablementDialog()
        } else if !apiKeyLoadAttempted {
            loadOrImportAPIKey(showFeedback: false)
        }
    }

    private func requestAccessibilityPermission(openSettings: Bool) {
        guard !AXIsProcessTrusted() else {
            continueOnboarding()
            return
        }
        accessibilityRequestIssuedThisRun = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if openSettings {
            NSWorkspace.shared.open(AppConfiguration.accessibilitySettingsURL)
        }
    }

    private func requestScreenRecordingPermission(openSettings: Bool) {
        guard !CGPreflightScreenCaptureAccess() else {
            continueOnboarding()
            return
        }
        screenRecordingRequestIssuedThisRun = true
        let granted = CGRequestScreenCaptureAccess()
        if openSettings {
            NSWorkspace.shared.open(AppConfiguration.screenRecordingSettingsURL)
        }
        if granted {
            DispatchQueue.main.async { [weak self] in
                self?.continueOnboarding()
            }
        }
    }

    private func loadOrImportAPIKey(
        showFeedback: Bool,
        forceImport: Bool = false
    ) {
        apiKeyLoadAttempted = true
        do {
            if let bootstrapped = try consumeBootstrapAPIKey() {
                try keychainStore.save(bootstrapped)
                apiKey = bootstrapped
            } else if !forceImport, let existing = try keychainStore.read() {
                apiKey = existing
            } else {
                let imported = try KeySourceParser.loadOpenAIKey(
                    from: AppConfiguration.sourceKeyURL
                )
                try keychainStore.save(imported)
                apiKey = imported
            }
            if showFeedback {
                hud.showSuccess(text: "API key loaded")
            }
        } catch {
            apiKey = nil
            if showFeedback {
                hud.showError(error.localizedDescription)
            }
            logger.error("The API key could not be loaded.")
        }
    }

    private func consumeBootstrapAPIKey() throws -> String? {
        let url = AppConfiguration.bootstrapKeyURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              key.count > 20
        else {
            try? FileManager.default.removeItem(at: url)
            throw KeySourceError.missingKey
        }
        try FileManager.default.removeItem(at: url)
        return key
    }

    private func handle(_ action: AIShortcutAction) {
        guard stateStore.enabledShortcutActions.contains(action) else {
            return
        }
        if action == .insert {
            toggleInsertPanel()
            return
        }
        if action == .clipboardQueue {
            toggleClipboardQueue()
            return
        }
        if action == .inputLock {
            guard Date() >= ignoreInputLockHotKeyUntil else {
                return
            }
            toggleInputLock()
            return
        }
        if action == .explain {
            if explanationPanel.isVisible {
                explanationPanel.dismiss()
                return
            }
            if explanationRequestInFlight {
                showExplanationPanel(
                    hasHiddenSelection: pendingExplanationHasHiddenSelection,
                    isLoading: true
                )
                return
            }
        }

        guard !isBusy else {
            hud.showBusy()
            return
        }
        guard stateStore.dataSharingAcknowledged else {
            hud.showError("Enable AI Shortcuts from the menu bar first")
            return
        }
        if action.requiresOpenAI {
            guard apiKey != nil else {
                hud.showError("OpenAI API key is unavailable")
                return
            }
        }
        if action.requiresAccessibility, !AXIsProcessTrusted() {
            requestAccessibilityPermission(openSettings: true)
            hud.showError("Turn on AI Shortcuts in Accessibility")
            return
        }
        if action.requiresScreenRecording, !CGPreflightScreenCaptureAccess() {
            requestScreenRecordingPermission(openSettings: true)
            hud.showError("Turn on AI Shortcuts in Screen Recording")
            return
        }

        beginOperation(action)
        switch action {
        case .ocr:
            activeTask = Task { @MainActor [weak self] in
                await self?.runOCR()
            }
        case .refine:
            activeTask = Task { @MainActor [weak self] in
                await self?.captureAndRunTextAction(.refine)
            }
        case .translate, .format:
            activeTask = Task { @MainActor [weak self] in
                await self?.captureAndRequestParameter(for: action)
            }
        case .explain:
            activeTask = Task { @MainActor [weak self] in
                await self?.captureAndShowExplanation()
            }
        case .calculate:
            activeTask = Task { @MainActor [weak self] in
                await self?.captureAndRequestCalculation()
            }
        case .finderPath:
            activeTask = Task { @MainActor [weak self] in
                await self?.runFinderPath()
            }
        case .inputLock:
            break
        case .clipboardQueue:
            break
        case .insert:
            break
        }
    }

    private func setShortcut(_ action: AIShortcutAction, enabled: Bool) {
        do {
            try hotKeyManager?.setEnabled(enabled, for: action)
            stateStore.setShortcut(action, enabled: enabled)

            if !enabled {
                if currentAction == action {
                    cancelCurrentOperation(showFeedback: false, message: "Shortcut disabled.")
                }
                if action == .inputLock, inputLockService.mode != nil {
                    deactivateInputLock(showFeedback: false)
                }
                if action == .clipboardQueue, clipboardQueueService.mode != .inactive {
                    clipboardQueueService.deactivate(notify: false)
                    clipboardQueueIndicator.dismiss()
                }
                if action == .explain, explanationPanel.isVisible {
                    explanationPanel.dismiss()
                }
                if action == .insert, insertPanel.isVisible {
                    insertPanel.dismiss()
                }
            }

        } catch {
            hud.showError(error.localizedDescription)
        }
    }

    private func toggleInsertPanel() {
        if insertPanel.isVisible {
            insertPanel.dismiss()
            return
        }
        guard !isBusy else {
            hud.showBusy()
            return
        }
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission(openSettings: true)
            hud.showError("Turn on AI Shortcuts in Accessibility to use Insert")
            return
        }

        insertTargetApplication = NSWorkspace.shared.frontmostApplication
        insertPanel.show(
            entries: allInsertionEntries(),
            onLookup: { [weak self] query in
                self?.resolveInsertion(query)
            },
            onCreate: { [weak self] key, value in
                guard let self else { return [] }
                try self.insertLibrary.add(key: key, value: value)
                return self.allInsertionEntries()
            },
            onUpdate: { [weak self] id, key, value in
                guard let self else { return [] }
                try self.insertLibrary.update(id: id, key: key, value: value)
                return self.allInsertionEntries()
            },
            onDelete: { [weak self] id in
                guard let self else { return [] }
                try self.insertLibrary.delete(id: id)
                return self.allInsertionEntries()
            }
        )
    }

    private func resolveInsertion(_ query: String) {
        let entries = allInsertionEntries()
        guard !entries.isEmpty else {
            insertPanel.showLookupError("No saved insertions · type /new to create one")
            return
        }
        if let match = InsertEntryMatcher.exactMatch(for: query, in: entries)
            ?? InsertEntryMatcher.uniqueContainedMatch(for: query, in: entries)
        {
            insertPanel.dismiss()
            activeTask = Task { @MainActor [weak self] in
                await self?.pasteInsertion(match)
            }
            return
        }
        guard stateStore.dataSharingAcknowledged else {
            insertPanel.showLookupError("No exact match · enable AI Shortcuts for smart matching")
            return
        }
        guard apiKey != nil else {
            insertPanel.showLookupError("No exact match · OpenAI API key is unavailable")
            return
        }

        insertPanel.setResolving(true)
        beginOperation(.insert)
        activeTask = Task { @MainActor [weak self] in
            await self?.resolveInsertionWithAI(query, entries: entries)
        }
    }

    private func resolveInsertionWithAI(
        _ query: String,
        entries: [InsertEntry]
    ) async {
        defer { finishOperation() }
        let prompt = PromptBuilder.makeInsertLookup(
            query: query,
            candidateKeys: entries.map(\.smartLookupLabel)
        )
        guard reserve(TokenEstimator.textReservation(for: prompt), for: .insert) else {
            insertPanel.showLookupError("Daily AI budget guard reached")
            return
        }
        do {
            let completion = try await callAPI(prompt: prompt)
            let response = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(response), entries.indices.contains(index) else {
                insertPanel.showLookupError("No reasonable matching key found")
                return
            }
            insertPanel.dismiss()
            await pasteInsertion(entries[index])
        } catch {
            guard !Task.isCancelled else {
                return
            }
            insertPanel.showLookupError(operationErrorMessage(error))
        }
    }

    private func pasteInsertion(_ entry: InsertEntry) async {
        let target = insertTargetApplication
        insertTargetApplication = nil
        let inserted = await selectionService.insertText(entry.value, into: target)
        if inserted {
            hud.showSuccess(text: "Inserted · \(entry.key)")
        } else {
            selectionService.placeOnClipboard(entry.value)
            hud.showError("Could not return to the original field · value copied")
        }
    }

    private func allInsertionEntries(now: Date = Date()) -> [InsertEntry] {
        let customEntries = insertLibrary.entries.filter {
            !InsertBuiltIns.conflicts(with: $0.key)
        }
        return InsertBuiltIns.entries(now: now) + customEntries
    }

    private func toggleClipboardQueue() {
        switch clipboardQueueService.mode {
        case .inactive:
            guard AXIsProcessTrusted() else {
                requestAccessibilityPermission(openSettings: true)
                hud.showError("Turn on AI Shortcuts in Accessibility to use Clipboard Queue")
                return
            }
            guard clipboardQueueService.startCollecting() else {
                hud.showError("Clipboard Queue could not start · check Accessibility permission")
                return
            }
        case .collecting:
            clipboardQueueService.beginPasting()
        case .pasting:
            clipboardQueueService.deactivate(notify: false)
            clipboardQueueIndicator.dismiss()
            hud.showSuccess(text: "Clipboard queue cancelled")
        }
    }

    private func handleClipboardQueueEvent(_ event: ClipboardQueueEvent) {
        switch event {
        case let .changed(mode, count):
            clipboardQueueIndicator.show(mode: mode, count: count)
            if mode == .inactive {
                hud.showSuccess(text: "Clipboard queue complete")
            }
        case .captureRejected:
            hud.showError("Clipboard queue limit reached · 50 items or 100 MB")
        }
    }

    private func toggleInputLock() {
        if inputLockService.mode != nil {
            deactivateInputLock(showFeedback: true)
            return
        }
        if inputLockPanel.isVisible {
            inputLockPanel.dismiss()
            return
        }
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission(openSettings: true)
            hud.showError("Turn on AI Shortcuts in Accessibility to use Input Lock")
            return
        }
        inputLockPanel.show { [weak self] mode in
            self?.activateInputLock(mode)
        }
    }

    private func activateInputLock(_ mode: InputLockMode) {
        if clipboardQueueService.mode != .inactive {
            clipboardQueueService.deactivate(notify: false)
            clipboardQueueIndicator.dismiss()
        }
        guard inputLockService.activate(mode) else {
            hud.showError("Input Lock could not start · check Accessibility permission")
            return
        }
        inputLockIndicator.show(mode: mode)
    }

    private func deactivateInputLock(showFeedback: Bool) {
        guard inputLockService.mode != nil else {
            return
        }
        inputLockService.deactivate()
        inputLockIndicator.dismiss()
        ignoreInputLockHotKeyUntil = Date().addingTimeInterval(0.6)
        if showFeedback {
            hud.showSuccess(text: "Input restored")
        }
    }

    private func runOCR() async {
        defer { finishOperation() }
        do {
            guard let capture = try await screenshotService.captureSelection() else {
                return
            }
            let prompt = PromptBuilder.make(action: .ocr)
            let reservation = TokenEstimator.imageReservation(
                for: prompt,
                pixelWidth: capture.pixelWidth,
                pixelHeight: capture.pixelHeight
            )
            guard reserve(reservation, for: .ocr) else {
                return
            }
            let completion = try await callAPI(prompt: prompt, imagePNGs: [capture.pngData])
            guard !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastAPIStatus = "No OCR text"
                hud.showError("No readable text found")
                return
            }
            selectionService.placeOnClipboard(completion.text)
            hud.showSuccess(text: "OCR copied")
        } catch {
            guard !Task.isCancelled else {
                return
            }
            handleOperationError(error, action: .ocr)
        }
    }

    private func captureAndRequestCalculation() async {
        do {
            guard let capture = try await screenshotService.captureSelection() else {
                finishOperation()
                return
            }

            let panel = PromptPanelController()
            promptPanel = panel
            panel.show(
                title: "Calculate",
                placeholder: "Optional instruction · e.g. total quantities and prices",
                allowsEmptySubmission: true
            ) { [weak self] instruction in
                guard let self else {
                    return
                }
                self.promptPanel = nil
                guard let instruction else {
                    self.finishOperation()
                    return
                }
                self.activeTask = Task { @MainActor [weak self] in
                    await self?.runScreenshotCalculation(
                        capture: capture,
                        instruction: instruction
                    )
                }
            }
        } catch {
            guard !Task.isCancelled else {
                finishOperation()
                return
            }
            handleOperationError(error, action: .calculate)
            finishOperation()
        }
    }

    private func runScreenshotCalculation(
        capture: ScreenshotCapture,
        instruction: String
    ) async {
        defer { finishOperation() }
        let prompt = PromptBuilder.make(
            action: .calculate,
            parameter: instruction
        )
        let reservation = TokenEstimator.imageReservation(
            for: prompt,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight
        )
        guard reserve(reservation, for: .calculate) else {
            return
        }

        do {
            let completion = try await callAPI(prompt: prompt, imagePNGs: [capture.pngData])
            guard let displayText = CalculateResultPresentation.clipboardText(for: completion.text) else {
                throw ResponsesAPIError.missingOutput
            }
            selectionService.placeOnClipboard(displayText)
            hud.showResult(text: displayText)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            handleOperationError(error, action: .calculate)
        }
    }

    private func runFinderPath() async {
        defer { finishOperation() }
        let authorization = await finderService.authorizationState(requestIfNeeded: true)
        finderAutomationAuthorization = authorization
        switch authorization {
        case .granted, .unavailable:
            break
        case .notDetermined:
            hud.showError("Allow Finder access in the macOS permission prompt")
            return
        case .denied:
            requestAutomationPermission(openSettings: true)
            hud.showError("Finder access is off · Privacy & Security → Automation")
            return
        case .finderNotRunning:
            hud.showError("Open Finder, then try Copy Finder Path again")
            return
        case .unknown:
            break
        }
        do {
            guard let result = try await finderService.currentPaths() else {
                hud.showError("Select a Finder file or folder first")
                return
            }
            let joined = result.paths.joined(separator: "\n")
            selectionService.placeOnClipboard(joined)
            let label: String
            switch result.source {
            case .selection:
                label = result.paths.count == 1
                    ? "Path copied"
                    : "\(result.paths.count) paths copied"
            }
            hud.showSuccess(text: label)
            finderAutomationAuthorization = .granted
        } catch FinderPathError.notAuthorized {
            finderAutomationAuthorization = .denied
            requestAutomationPermission(openSettings: true)
            hud.showError("Finder access is off · Privacy & Security → Automation")
        } catch {
            hud.showError(error.localizedDescription)
        }
    }

    private func refreshFinderAutomationAuthorization() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            finderAutomationAuthorization = await finderService.authorizationState(
                requestIfNeeded: false
            )
        }
    }

    private func requestFinderAutomationPermission() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let authorization = await finderService.authorizationState(requestIfNeeded: true)
            finderAutomationAuthorization = authorization
            switch authorization {
            case .granted:
                hud.showSuccess(text: "Finder access granted")
            case .notDetermined:
                hud.showError("Allow Finder access in the macOS permission prompt")
            case .denied:
                requestAutomationPermission(openSettings: true)
                hud.showError("Finder access is off · Automation settings opened")
            case .finderNotRunning:
                hud.showError("Open Finder, then request Finder Automation again")
            case .unknown, .unavailable:
                hud.showError("Finder permission status is unavailable")
            }
        }
    }

    private func requestAutomationPermission(openSettings: Bool) {
        if openSettings {
            NSWorkspace.shared.open(AppConfiguration.automationSettingsURL)
        }
    }

    private func captureAndRunTextAction(_ action: AIShortcutAction) async {
        guard let snapshot = await selectionService.captureSelection() else {
            hud.showError("Select some text first")
            finishOperation()
            return
        }
        await runTextAction(action, snapshot: snapshot, parameter: nil)
    }

    private func captureAndRequestParameter(for action: AIShortcutAction) async {
        guard let snapshot = await selectionService.captureSelection() else {
            hud.showError("Select some text first")
            finishOperation()
            return
        }

        let panel = PromptPanelController()
        promptPanel = panel
        let promptTitle: String
        let promptPlaceholder: String
        switch action {
        case .translate:
            promptTitle = "Translate"
            promptPlaceholder = "e.g. Japanese, formal"
        case .format:
            promptTitle = "Format"
            promptPlaceholder = "e.g. concise email with bullets"
        default:
            promptTitle = action.displayName
            promptPlaceholder = "Add an instruction"
        }
        panel.show(
            title: promptTitle,
            placeholder: promptPlaceholder
        ) { [weak self] parameter in
            guard let self else {
                return
            }
            self.promptPanel = nil
            self.selectionService.reactivate(snapshot)
            guard let parameter else {
                self.finishOperation()
                return
            }
            self.activeTask = Task { @MainActor [weak self] in
                await self?.runTextAction(action, snapshot: snapshot, parameter: parameter)
            }
        }
    }

    private func runTextAction(
        _ action: AIShortcutAction,
        snapshot: SelectionSnapshot,
        parameter: String?
    ) async {
        defer { finishOperation() }
        let prompt = PromptBuilder.make(
            action: action,
            selectedText: snapshot.text,
            parameter: parameter
        )
        let reservation = TokenEstimator.textReservation(for: prompt)
        guard reserve(reservation, for: action) else {
            return
        }

        do {
            let completion = try await callAPI(prompt: prompt)
            guard !completion.text.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            if action == .translate {
                selectionService.placeOnClipboard(completion.text)
                hud.showSuccess(text: "Translation copied")
            } else {
                let replaced = await selectionService.replaceIfUnchanged(
                    snapshot,
                    with: completion.text
                )
                let outcome = action == .refine ? "Refined" : "Formatted"
                hud.showSuccess(
                    text: replaced ? "\(outcome) · replaced" : "\(outcome) · copied"
                )
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }
            handleOperationError(error, action: action)
        }
    }

    private func captureAndShowExplanation() async {
        let captureStart = Date()
        let hadConversation = !explanationMemory.exchanges.isEmpty
        let activeExchanges = explanationMemory.activeExchanges()
        if hadConversation, activeExchanges.isEmpty {
            explanationPanel.resetDraft()
        }

        let snapshot = await selectionService.captureSelection(preserveClipboard: true)
        guard !Task.isCancelled else {
            finishOperation()
            return
        }
        pendingExplanationSelection = snapshot
        finishOperation()
        let captureMilliseconds = Int(
            Date().timeIntervalSince(captureStart) * 1_000
        )
        logger.notice(
            "Prepared Explain context in \(captureMilliseconds, privacy: .public) ms; hidden selection: \(snapshot != nil, privacy: .public)."
        )
        explanationPanel.show(
            exchanges: activeExchanges,
            hasHiddenSelection: snapshot != nil,
            isLoading: false,
            onSubmit: { [weak self] request, imagePNGs in
                self?.submitExplanation(request, imagePNGs: imagePNGs)
            }
        )
    }

    private func showExplanationPanel(
        hasHiddenSelection: Bool,
        isLoading: Bool
    ) {
        explanationPanel.show(
            exchanges: explanationMemory.activeExchanges(),
            hasHiddenSelection: hasHiddenSelection,
            isLoading: isLoading,
            pendingRequest: Self.explanationDisplayRequest(
                pendingExplanationRequest ?? "",
                imageCount: pendingExplanationImagePNGs.count
            ),
            onSubmit: { [weak self] request, imagePNGs in
                self?.submitExplanation(request, imagePNGs: imagePNGs)
            }
        )
    }

    private func submitExplanation(_ rawRequest: String, imagePNGs: [Data]) {
        let request = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pendingExplanationSelection != nil || !request.isEmpty || !imagePNGs.isEmpty else {
            return
        }
        guard !isBusy, !explanationRequestInFlight else {
            explanationPanel.showError("Another AI shortcut is still working.")
            return
        }

        let snapshot = pendingExplanationSelection
        pendingExplanationSelection = nil
        pendingExplanationRequest = request
        pendingExplanationImagePNGs = imagePNGs
        pendingExplanationHasHiddenSelection = snapshot != nil
        explanationRequestInFlight = true
        explanationPanel.setLoading(request: request, imageCount: imagePNGs.count)

        beginOperation(.explain)
        activeTask = Task { @MainActor [weak self] in
            await self?.runExplanation(
                snapshot: snapshot,
                request: request,
                imagePNGs: imagePNGs
            )
        }
    }

    private func runExplanation(
        snapshot: SelectionSnapshot?,
        request: String,
        imagePNGs: [Data]
    ) async {
        defer {
            explanationRequestInFlight = false
            pendingExplanationRequest = nil
            pendingExplanationImagePNGs.removeAll()
            pendingExplanationHasHiddenSelection = false
            finishOperation()
        }

        let modelRequest = request.isEmpty && !imagePNGs.isEmpty
            ? "Explain the attached image."
            : request
        let prompt = PromptBuilder.make(
            action: .explain,
            selectedText: snapshot?.text,
            parameter: modelRequest,
            conversationContext: explanationMemory.context()
        )
        let pixelSizes = imagePNGs.compactMap(Self.pixelSize(ofPNG:))
        let reservation = imagePNGs.isEmpty
            ? TokenEstimator.textReservation(for: prompt)
            : TokenEstimator.multimodalReservation(for: prompt, pixelSizes: pixelSizes)
        guard reserve(reservation, for: .explain, showFeedback: false) else {
            pendingExplanationSelection = snapshot
            explanationPanel.showError(
                "The GPT-5.4 daily guard blocked this request.",
                retryRequest: request,
                retryImagePNGs: imagePNGs,
                hasHiddenSelection: snapshot != nil
            )
            return
        }

        do {
            let completion = try await callAPI(prompt: prompt, imagePNGs: imagePNGs)
            guard !completion.text.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            explanationMemory.record(
                highlightedText: snapshot?.text ?? "",
                request: Self.explanationDisplayRequest(request, imageCount: imagePNGs.count),
                explanation: completion.text
            )
            explanationPanel.complete(with: explanationMemory.activeExchanges())
        } catch {
            guard !Task.isCancelled else {
                return
            }
            pendingExplanationSelection = snapshot
            explanationPanel.showError(
                operationErrorMessage(error),
                retryRequest: request,
                retryImagePNGs: imagePNGs,
                hasHiddenSelection: snapshot != nil
            )
        }
    }

    private func reserve(
        _ amount: Int,
        for action: AIShortcutAction,
        showFeedback: Bool = true
    ) -> Bool {
        switch fullBudget.reserve(amount) {
        case let .reserved(state):
            stateStore.saveFullBudgetState(state)
            return true
        case let .refused(remaining, requested):
            lastAPIStatus = "GPT-5.4 budget blocked"
            if showFeedback {
                hud.showError(
                    "GPT-5.4 daily guard blocked \(requested.formatted()) tokens; \(remaining.formatted()) remain"
                )
            }
            return false
        }
    }

    private func normalizeAndSaveBudgets() {
        fullBudget.normalize()
        stateStore.saveFullBudgetState(fullBudget.state)
    }

    private func callAPI(
        prompt: PromptSpec,
        imagePNGs: [Data] = []
    ) async throws -> AICompletion {
        guard let apiKey else {
            throw KeySourceError.missingKey
        }
        let start = Date()
        do {
            let completion = try await apiClient.complete(
                prompt: prompt,
                imagePNGs: imagePNGs,
                apiKey: apiKey,
                safetyIdentifier: stateStore.safetyIdentifier
            )
            lastAPIStatus = "Success"
            let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
            logger.notice(
                "Completed \(prompt.action.displayName, privacy: .public) in \(milliseconds, privacy: .public) ms."
            )
            return completion
        } catch {
            lastAPIStatus = "Error"
            let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
            let errorDetails = error as NSError
            logger.error(
                "Failed \(prompt.action.displayName, privacy: .public) after \(milliseconds, privacy: .public) ms; \(errorDetails.domain, privacy: .public) \(errorDetails.code, privacy: .public)."
            )
            throw error
        }
    }

    private func handleOperationError(_ error: Error, action: AIShortcutAction) {
        hud.showError(operationErrorMessage(error))
    }

    private func operationErrorMessage(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet:
                return "Network unavailable — check VPN or Wi-Fi and try again."
            case .networkConnectionLost:
                return "Connection was interrupted — press Enter to retry."
            case .timedOut:
                return "OpenAI took too long — press Enter to retry."
            default:
                return "OpenAI connection failed — press Enter to retry."
            }
        }
        return error.localizedDescription
    }

    private func beginOperation(_ action: AIShortcutAction) {
        operationGeneration &+= 1
        let generation = operationGeneration
        isBusy = true
        currentAction = action
        statusMenu.setBusy(true)

        operationTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isBusy,
                  self.operationGeneration == generation else {
                return
            }
            self.cancelCurrentOperation(
                showFeedback: false,
                message: "Operation timed out — shortcuts are ready"
            )
        }
        operationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
    }

    private func finishOperation() {
        guard isBusy else {
            return
        }
        operationTimeout?.cancel()
        operationTimeout = nil
        activeTask = nil
        currentAction = nil
        isBusy = false
        statusMenu.setBusy(false)
    }

    private func cancelCurrentOperation(
        showFeedback: Bool,
        message: String? = nil
    ) {
        guard isBusy else {
            return
        }

        let cancelledAction = currentAction
        let task = activeTask
        activeTask = nil
        task?.cancel()
        screenshotService.cancelCapture()

        let panel = promptPanel
        promptPanel = nil
        panel?.cancel()

        if cancelledAction == .explain {
            let retryRequest = pendingExplanationRequest
            let retryImages = pendingExplanationImagePNGs
            explanationRequestInFlight = false
            pendingExplanationRequest = nil
            pendingExplanationImagePNGs.removeAll()
            pendingExplanationHasHiddenSelection = false
            explanationPanel.showError(
                message ?? "Request cancelled.",
                retryRequest: retryRequest,
                retryImagePNGs: retryImages,
                hasHiddenSelection: pendingExplanationSelection != nil
            )
        }
        finishOperation()
        if cancelledAction == .explain {
            return
        } else if let message {
            hud.showError(message)
        } else if showFeedback {
            hud.showSuccess(text: "Cancelled")
        }
    }

    private static func pixelSize(ofPNG data: Data) -> (width: Int, height: Int)? {
        guard let representation = NSBitmapImageRep(data: data) else {
            return nil
        }
        return (representation.pixelsWide, representation.pixelsHigh)
    }

    private static func explanationDisplayRequest(_ request: String, imageCount: Int) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageCount > 0 else {
            return trimmed
        }
        let label = imageCount == 1 ? "Image attached" : "\(imageCount) images attached"
        return trimmed.isEmpty ? label : "\(trimmed)\n\(label)"
    }
}
