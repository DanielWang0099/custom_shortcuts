import AppKit
import ApplicationServices
import AIShortcutsCore
import AIShortcutsRendering
import CoreGraphics
import Darwin
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
    private let apiClient = AIProviderClient()

    // AppKit panels (especially WKWebView) dominate idle memory. Keep only
    // lightweight state and Carbon registrations resident, then construct the
    // exact resources an action needs on its key-down event.
    private var selectionServiceStorage: SelectionService?
    private var screenshotServiceStorage: ScreenshotService?
    private var finderServiceStorage: FinderSelectionService?
    private var hudStorage: HUDController?
    private var richTextRendererStorage: NativeRichTextRenderer?
    private var modelSettingsStorage: ModelSettingsWindowController?
    private var explanationPanelStorage: ExplanationPanelController?
    private var inputLockPanelStorage: InputLockPanelController?
    private var insertPanelStorage: InsertPanelController?
    private var insertLibraryStorage: InsertLibraryStore?
    private var shortcutGuideStorage: ShortcutGuideWindowController?
    private var inputLockIndicatorStorage: InputLockIndicatorController?
    private var clipboardQueueIndicatorStorage: ClipboardQueueIndicatorController?
    private var welcomeWindowStorage: WelcomeWindowController?
    private var inputLockServiceStorage: InputLockService?
    private var clipboardQueueServiceStorage: ClipboardQueueService?

    private var hotKeyManager: HotKeyManager?
    private var promptPanel: PromptPanelController?
    private var singleInstanceLock: SingleInstanceLock?
    private var apiKey: String?
    private var cachedSafetyIdentifier = ""
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
    private var apiKeyLoadAttempted = false
    private var accessibilityRequestIssuedThisRun = false
    private var screenRecordingRequestIssuedThisRun = false
    private var isUserIntentionalQuit = false
    private var resourceTrimWorkItem: DispatchWorkItem?
    private var idleSleepWorkItem: DispatchWorkItem?
    private var latencyActivityEndWorkItem: DispatchWorkItem?
    private var latencyActivity: NSObjectProtocol?
    private var networkPreconnectTask: Task<Void, Never>?
    private var preconnectGeneration = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var runtimeIsSleeping = true

    private static let resourceTrimDelay: TimeInterval = 30
    private static let runtimeIdleDelay: TimeInterval = 90
    private static let latencyWakeDuration: TimeInterval = 4

    private var selectionService: SelectionService {
        if let selectionServiceStorage {
            return selectionServiceStorage
        }
        let service = SelectionService()
        selectionServiceStorage = service
        return service
    }

    private var screenshotService: ScreenshotService {
        if let screenshotServiceStorage {
            return screenshotServiceStorage
        }
        let service = ScreenshotService()
        screenshotServiceStorage = service
        return service
    }

    private var finderService: FinderSelectionService {
        if let finderServiceStorage {
            return finderServiceStorage
        }
        let service = FinderSelectionService()
        finderServiceStorage = service
        return service
    }

    private var hud: HUDController {
        if let hudStorage {
            return hudStorage
        }
        let controller = HUDController()
        hudStorage = controller
        return controller
    }

    private var richTextRenderer: NativeRichTextRenderer {
        if let richTextRendererStorage {
            return richTextRendererStorage
        }
        let renderer = NativeRichTextRenderer()
        richTextRendererStorage = renderer
        return renderer
    }

    private var modelSettings: ModelSettingsWindowController {
        if let modelSettingsStorage {
            return modelSettingsStorage
        }
        let controller = ModelSettingsWindowController()
        modelSettingsStorage = controller
        return controller
    }

    private var explanationPanel: ExplanationPanelController {
        if let explanationPanelStorage {
            return explanationPanelStorage
        }
        let controller = ExplanationPanelController()
        explanationPanelStorage = controller
        return controller
    }

    private var inputLockPanel: InputLockPanelController {
        if let inputLockPanelStorage {
            return inputLockPanelStorage
        }
        let controller = InputLockPanelController()
        inputLockPanelStorage = controller
        return controller
    }

    private var insertPanel: InsertPanelController {
        if let insertPanelStorage {
            return insertPanelStorage
        }
        let controller = InsertPanelController()
        insertPanelStorage = controller
        return controller
    }

    private var insertLibrary: InsertLibraryStore {
        if let insertLibraryStorage {
            return insertLibraryStorage
        }
        let store = InsertLibraryStore()
        insertLibraryStorage = store
        return store
    }

    private var shortcutGuide: ShortcutGuideWindowController {
        if let shortcutGuideStorage {
            return shortcutGuideStorage
        }
        let controller = ShortcutGuideWindowController()
        shortcutGuideStorage = controller
        return controller
    }

    private var inputLockIndicator: InputLockIndicatorController {
        if let inputLockIndicatorStorage {
            return inputLockIndicatorStorage
        }
        let controller = InputLockIndicatorController()
        inputLockIndicatorStorage = controller
        return controller
    }

    private var clipboardQueueIndicator: ClipboardQueueIndicatorController {
        if let clipboardQueueIndicatorStorage {
            return clipboardQueueIndicatorStorage
        }
        let controller = ClipboardQueueIndicatorController()
        clipboardQueueIndicatorStorage = controller
        return controller
    }

    private var welcomeWindow: WelcomeWindowController {
        if let welcomeWindowStorage {
            return welcomeWindowStorage
        }
        let controller = WelcomeWindowController(stateStore: stateStore)
        controller.onOpenModelSettings = { [weak self] in
            self?.showModelSettings()
        }
        welcomeWindowStorage = controller
        return controller
    }

    private var inputLockService: InputLockService {
        if let inputLockServiceStorage {
            return inputLockServiceStorage
        }
        let service = InputLockService { [weak self] in
            Task(priority: .userInitiated) { @MainActor [weak self] in
                self?.deactivateInputLock(showFeedback: true)
            }
        }
        inputLockServiceStorage = service
        return service
    }

    private var clipboardQueueService: ClipboardQueueService {
        if let clipboardQueueServiceStorage {
            return clipboardQueueServiceStorage
        }
        let service = ClipboardQueueService { [weak self] event in
            Task(priority: .userInitiated) { @MainActor [weak self] in
                self?.handleClipboardQueueEvent(event)
            }
        }
        clipboardQueueServiceStorage = service
        return service
    }

    private lazy var statusMenu = StatusMenuController { [weak self] in
        self?.menuSnapshot() ?? StatusMenuSnapshot(
            busy: false,
            enabled: false,
            keyReady: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            finderAutomationAuthorization: .unknown,
            lastAPIStatus: "Unavailable",
            currentAction: nil,
            enabledShortcutActions: Set(AIShortcutAction.allCases),
            providerSummary: AIProviderConfiguration.defaultConfiguration(
                for: .openAICompatible
            ).summary
        )
    }

    override init() {
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

        cachedSafetyIdentifier = stateStore.safetyIdentifier
        configureApplicationMenu()
        configureMenuActions()
        configureMemoryPressureHandling()
        _ = statusMenu

        do {
            hotKeyManager = try HotKeyManager(
                enabledActions: stateStore.enabledShortcutActions,
                onActivationChord: { [weak self] in
                    self?.wakeForActivationChord()
                },
                onActionPressed: { [weak self] action in
                    self?.prepareForAction(action)
                }
            ) { [weak self] action in
                self?.handle(action)
            }
        } catch {
            hud.showError(error.localizedDescription)
            logger.error("Global shortcut registration failed.")
        }

        preloadStoredAPIKey()
        refreshFinderAutomationAuthorization()
        scheduleIdleSleep()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.stateStore.welcomeDismissed {
                self.welcomeWindow.show()
            }
            self.continueOnboarding()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        markRuntimeActivity(preconnect: false, latencyCritical: false)
        continueOnboarding()
    }

    func applicationWillTerminate(_ notification: Notification) {
        resourceTrimWorkItem?.cancel()
        idleSleepWorkItem?.cancel()
        latencyActivityEndWorkItem?.cancel()
        networkPreconnectTask?.cancel()
        memoryPressureSource?.cancel()
        apiClient.suspendConnection()
        endLatencyActivity()
        hotKeyManager?.invalidate()

        inputLockServiceStorage?.deactivate()
        inputLockIndicatorStorage?.dismiss()
        clipboardQueueServiceStorage?.deactivate(notify: false)
        clipboardQueueIndicatorStorage?.dismiss()

        if !isUserIntentionalQuit && (screenRecordingRequestIssuedThisRun || accessibilityRequestIssuedThisRun) {
            logger.notice("Relaunching AI Shortcuts following privacy permission update.")
            relaunchAfterTermination()
        }
    }

    private func relaunchAfterTermination() {
        let bundleURL = Bundle.main.bundleURL
        let bundlePath = bundleURL.path
        let command: String
        if bundlePath.hasSuffix(".app") {
            command = "sleep 0.5; open -a '\(bundlePath)'"
        } else {
            let executablePath = CommandLine.arguments[0]
            command = "sleep 0.5; '\(executablePath)'"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func configureMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.enterIdleMode()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func wakeForActivationChord() {
        markRuntimeActivity(preconnect: true, latencyCritical: true)
    }

    private func prepareForAction(_ action: AIShortcutAction) {
        markRuntimeActivity(
            preconnect: action.requiresAIProvider,
            latencyCritical: true
        )

        switch action {
        case .ocr:
            _ = screenshotService
        case .refine:
            _ = selectionService
        case .translate, .format:
            _ = selectionService
            if promptPanel == nil {
                promptPanel = PromptPanelController()
            }
        case .explain:
            _ = selectionService
            explanationPanel.prepare()
        case .calculate:
            _ = screenshotService
            if promptPanel == nil {
                promptPanel = PromptPanelController()
            }
        case .finderPath:
            finderService.prepare()
        case .inputLock:
            _ = inputLockService
            _ = inputLockPanel
        case .clipboardQueue:
            _ = clipboardQueueService
            _ = clipboardQueueIndicator
        case .insert:
            _ = selectionService
            _ = insertLibrary
            _ = insertPanel
        }
    }

    private func markRuntimeActivity(
        preconnect: Bool,
        latencyCritical: Bool
    ) {
        resourceTrimWorkItem?.cancel()
        resourceTrimWorkItem = nil
        idleSleepWorkItem?.cancel()
        idleSleepWorkItem = nil
        if runtimeIsSleeping {
            runtimeIsSleeping = false
            logger.debug("Runtime entered ready mode.")
        }
        if latencyCritical {
            beginLatencyActivity()
            scheduleLatencyActivityEnd()
        }
        if preconnect, apiKey != nil {
            apiClient.prepareConnection()
            startNetworkPreconnectionIfNeeded()
        }
        scheduleResourceTrim()
        scheduleIdleSleep()
    }

    private func startNetworkPreconnectionIfNeeded() {
        guard networkPreconnectTask == nil else {
            return
        }
        let endpoint = stateStore
            .aiProviderConfiguration(for: stateStore.aiProvider)
            .endpoint
        let client = apiClient
        preconnectGeneration &+= 1
        let generation = preconnectGeneration
        networkPreconnectTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            await client.preconnect(to: endpoint)
            guard !Task.isCancelled,
                  let self,
                  self.preconnectGeneration == generation
            else {
                return
            }
            self.networkPreconnectTask = nil
        }
    }

    private func beginLatencyActivity() {
        latencyActivityEndWorkItem?.cancel()
        latencyActivityEndWorkItem = nil
        guard latencyActivity == nil else {
            return
        }
        latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Responding to an AI Shortcuts activation"
        )
    }

    private func scheduleLatencyActivityEnd(
        after requestedDelay: TimeInterval? = nil
    ) {
        let delay = requestedDelay ?? Self.latencyWakeDuration
        latencyActivityEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isBusy else {
                return
            }
            self.endLatencyActivity()
        }
        latencyActivityEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func endLatencyActivity() {
        latencyActivityEndWorkItem?.cancel()
        latencyActivityEndWorkItem = nil
        guard let latencyActivity else {
            return
        }
        self.latencyActivity = nil
        ProcessInfo.processInfo.endActivity(latencyActivity)
    }

    private func scheduleIdleSleep(
        after requestedDelay: TimeInterval? = nil
    ) {
        let delay = requestedDelay ?? Self.runtimeIdleDelay
        idleSleepWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.enterIdleMode()
        }
        idleSleepWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleResourceTrim(
        after requestedDelay: TimeInterval? = nil
    ) {
        let delay = requestedDelay ?? Self.resourceTrimDelay
        resourceTrimWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.enterStandbyMode()
        }
        resourceTrimWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func enterStandbyMode() {
        resourceTrimWorkItem = nil
        releaseDormantResources()
        guard !hasActiveResidentFeature else {
            scheduleResourceTrim(after: 15)
            return
        }
        releaseAllocatorPages()
        logger.debug("Runtime entered network-ready standby mode.")
    }

    private func enterIdleMode() {
        resourceTrimWorkItem?.cancel()
        resourceTrimWorkItem = nil
        idleSleepWorkItem = nil
        releaseDormantResources()

        let wasSleeping = runtimeIsSleeping
        if !requiresWarmNetworkWhileIdle {
            suspendNetworkResidency()
        }
        guard !hasActiveResidentFeature else {
            scheduleResourceTrim(after: 15)
            scheduleIdleSleep(after: 15)
            if !wasSleeping, runtimeIsSleeping {
                releaseAllocatorPages()
            }
            return
        }

        suspendNetworkResidency()
        releaseAllocatorPages()
        logger.debug("Runtime entered low-memory sleep mode.")
    }

    private func suspendNetworkResidency() {
        guard !runtimeIsSleeping else {
            return
        }
        preconnectGeneration &+= 1
        networkPreconnectTask?.cancel()
        networkPreconnectTask = nil
        apiClient.suspendConnection()
        endLatencyActivity()
        runtimeIsSleeping = true
    }

    private func releaseAllocatorPages() {
        // Return allocator pages after the large AppKit/WebKit object graphs
        // have been released. This runs off the main thread and only at idle.
        DispatchQueue.global(qos: .utility).async {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    private var hasActiveResidentFeature: Bool {
        isBusy
            || statusMenu.isOpen
            || promptPanel?.isVisible == true
            || modelSettingsStorage?.isVisible == true
            || welcomeWindowStorage?.isVisible == true
            || shortcutGuideStorage?.isVisible == true
            || explanationPanelStorage?.isVisible == true
            || insertPanelStorage?.isVisible == true
            || inputLockPanelStorage?.isVisible == true
            || hudStorage?.isVisible == true
    }

    private var requiresWarmNetworkWhileIdle: Bool {
        isBusy
            || promptPanel?.isVisible == true
            || explanationPanelStorage?.isVisible == true
            || insertPanelStorage?.isVisible == true
    }

    private func releaseDormantResources() {
        if promptPanel?.isVisible != true {
            promptPanel = nil
        }
        if modelSettingsStorage?.isVisible != true {
            modelSettingsStorage = nil
        }
        if welcomeWindowStorage?.isVisible != true {
            welcomeWindowStorage = nil
        }
        if shortcutGuideStorage?.isVisible != true {
            shortcutGuideStorage = nil
        }
        if explanationPanelStorage?.isVisible != true,
           !explanationRequestInFlight
        {
            explanationPanelStorage?.releaseResources()
            explanationPanelStorage = nil
        }
        if insertPanelStorage?.isVisible != true {
            insertPanelStorage = nil
            insertLibraryStorage = nil
        }
        if inputLockPanelStorage?.isVisible != true {
            inputLockPanelStorage = nil
        }
        if hudStorage?.isVisible != true {
            hudStorage?.dismiss()
            hudStorage = nil
        }
        if inputLockServiceStorage?.mode == nil {
            inputLockServiceStorage = nil
            inputLockIndicatorStorage = nil
        }
        if (clipboardQueueServiceStorage?.mode ?? .inactive) == .inactive {
            clipboardQueueServiceStorage = nil
            clipboardQueueIndicatorStorage = nil
        }
        if !isBusy {
            selectionServiceStorage = nil
            screenshotServiceStorage = nil
            finderServiceStorage = nil
            richTextRendererStorage = nil
        }
    }

    private func configureMenuActions() {
        statusMenu.onWillOpen = { [weak self] in
            guard let self else { return }
            self.markRuntimeActivity(preconnect: false, latencyCritical: false)
            self.refreshFinderAutomationAuthorization()
        }
        statusMenu.onOpenWelcome = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.welcomeWindow.show()
        }
        statusMenu.onOpenModelSettings = { [weak self] in
            self?.showModelSettings()
        }
        statusMenu.onReloadKey = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.loadOrImportAPIKey(showFeedback: true, forceImport: true)
        }
        statusMenu.onOpenAccessibilitySettings = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.requestAccessibilityPermission(openSettings: true)
        }
        statusMenu.onOpenScreenRecordingSettings = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.requestScreenRecordingPermission(openSettings: true)
        }
        statusMenu.onRequestFinderAutomation = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.requestFinderAutomationPermission()
        }
        statusMenu.onCancelOperation = { [weak self] in
            self?.cancelCurrentOperation(showFeedback: true)
        }
        statusMenu.onOpenShortcutGuide = { [weak self] in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: true)
            self?.shortcutGuide.show()
        }
        statusMenu.onToggleShortcut = { [weak self] action, enabled in
            self?.markRuntimeActivity(preconnect: false, latencyCritical: false)
            self?.setShortcut(action, enabled: enabled)
        }
        statusMenu.onQuit = { [weak self] in
            self?.isUserIntentionalQuit = true
            NSApp.terminate(nil)
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "AI Shortcuts")
        let aboutItem = NSMenuItem(title: "About AI Shortcuts", action: #selector(openWelcomeWindow), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Model Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit AI Shortcuts", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openWelcomeWindow() {
        markRuntimeActivity(preconnect: false, latencyCritical: true)
        welcomeWindow.show()
    }

    @objc private func openSettingsFromMenu() {
        showModelSettings()
    }

    @objc private func quitFromMenu() {
        isUserIntentionalQuit = true
        NSApp.terminate(nil)
    }

    private func menuSnapshot() -> StatusMenuSnapshot {
        let provider = stateStore.aiProvider
        let configuration = stateStore.aiProviderConfiguration(for: provider)
        let keyReady = apiKey != nil
        let accessibilityGranted = AXIsProcessTrusted()
        return StatusMenuSnapshot(
            busy: isBusy,
            enabled: keyReady && accessibilityGranted,
            keyReady: keyReady,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            finderAutomationAuthorization: finderAutomationAuthorization,
            lastAPIStatus: lastAPIStatus,
            currentAction: currentAction?.displayName,
            enabledShortcutActions: stateStore.enabledShortcutActions,
            providerSummary: configuration.summary
        )
    }

    private func showModelSettings() {
        markRuntimeActivity(preconnect: false, latencyCritical: true)
        guard !isBusy else {
            hud.showBusy()
            return
        }
        let configurations = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { provider in
            (provider, stateStore.aiProviderConfiguration(for: provider))
        })
        modelSettings.show(
            configurations: configurations,
            selectedProvider: stateStore.aiProvider
        ) { [weak self] configuration, apiKey in
            self?.saveModelSettings(configuration, apiKey: apiKey)
        }
    }

    private func saveModelSettings(
        _ configuration: AIProviderConfiguration,
        apiKey: String?
    ) {
        guard configuration.validationMessage == nil else {
            hud.showError(configuration.validationMessage ?? "Model settings are invalid.")
            return
        }
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAPIKey, !trimmedAPIKey.isEmpty, trimmedAPIKey.count <= 20 {
            hud.showError("The API key looks too short.")
            return
        }
        do {
            if let trimmedAPIKey, !trimmedAPIKey.isEmpty {
                try keychainStore.save(trimmedAPIKey, for: configuration.provider)
            }
            let selectedAPIKey = try keychainStore.read(for: configuration.provider)
            stateStore.saveAIProviderConfiguration(configuration)
            stateStore.aiProvider = configuration.provider
            apiKeyLoadAttempted = true
            self.apiKey = selectedAPIKey
            suspendNetworkResidency()
            markRuntimeActivity(preconnect: true, latencyCritical: false)
            hud.showSuccess(text: "Model settings saved")
        } catch {
            self.apiKey = nil
            hud.showError(error.localizedDescription)
            logger.error("Model settings could not be saved.")
        }
    }

    private func continueOnboarding(userInitiated: Bool = false) {
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

        if !apiKeyLoadAttempted {
            loadOrImportAPIKey(showFeedback: false)
        }
    }

    private func preloadStoredAPIKey() {
        guard !apiKeyLoadAttempted else {
            return
        }
        do {
            guard let storedKey = try keychainStore.read(for: stateStore.aiProvider) else {
                return
            }
            apiKey = storedKey
            apiKeyLoadAttempted = true
            markRuntimeActivity(preconnect: true, latencyCritical: false)
        } catch {
            logger.error("The stored API key could not be preloaded.")
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

    @discardableResult
    private func loadOrImportAPIKey(
        showFeedback: Bool,
        forceImport: Bool = false
    ) -> Bool {
        apiKeyLoadAttempted = true
        let provider = stateStore.aiProvider
        do {
            if provider != .openAICompatible {
                try? FileManager.default.removeItem(at: AppConfiguration.bootstrapKeyURL)
            }
            if provider == .openAICompatible, let bootstrapped = try consumeBootstrapAPIKey() {
                try keychainStore.save(bootstrapped, for: provider)
                apiKey = bootstrapped
            } else if !forceImport, let existing = try keychainStore.read(for: provider) {
                apiKey = existing
            } else {
                guard let entered = promptForAPIKey(for: provider) else {
                    return false
                }
                try keychainStore.save(entered, for: provider)
                apiKey = entered
            }
            suspendNetworkResidency()
            markRuntimeActivity(preconnect: true, latencyCritical: false)
            if showFeedback {
                hud.showSuccess(text: "API key loaded")
            }
            return true
        } catch {
            apiKey = nil
            if showFeedback {
                hud.showError(error.localizedDescription)
            }
            logger.error("The API key could not be loaded.")
            return false
        }
    }

    private func promptForAPIKey(for provider: AIProvider) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add your \(provider.displayName) API key"
        alert.informativeText = """
        AI Shortcuts uses your own \(provider.displayName) account. The key is stored in your macOS login Keychain and is not written to the repository or logged.

        You can change it later with Reload API Key in the menu bar.
        """

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Paste your API key"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Key")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 20 else {
            hud.showError("The API key is missing or too short")
            return nil
        }
        return value
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
        markRuntimeActivity(
            preconnect: action.requiresAIProvider,
            latencyCritical: true
        )
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
        if action.requiresAIProvider {
            guard apiKey != nil else {
                hud.showError("API key is unavailable")
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
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.runOCR()
            }
        case .refine:
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.captureAndRunTextAction(.refine)
            }
        case .translate, .format:
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.captureAndRequestParameter(for: action)
            }
        case .explain:
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.captureAndShowExplanation()
            }
        case .calculate:
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.captureAndRequestCalculation()
            }
        case .finderPath:
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
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
                if action == .inputLock, inputLockServiceStorage?.mode != nil {
                    deactivateInputLock(showFeedback: false)
                }
                if action == .clipboardQueue,
                   (clipboardQueueServiceStorage?.mode ?? .inactive) != .inactive
                {
                    clipboardQueueServiceStorage?.deactivate(notify: false)
                    clipboardQueueIndicatorStorage?.dismiss()
                }
                if action == .explain, explanationPanelStorage?.isVisible == true {
                    explanationPanelStorage?.dismiss()
                }
                if action == .insert, insertPanelStorage?.isVisible == true {
                    insertPanelStorage?.dismiss()
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
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.pasteInsertion(match)
            }
            return
        }
        guard apiKey != nil else {
            insertPanel.showLookupError("No exact match · API key is unavailable")
            return
        }

        insertPanel.setResolving(true)
        beginOperation(.insert)
        activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
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
            if mode == .inactive {
                clipboardQueueIndicatorStorage?.dismiss()
                markRuntimeActivity(preconnect: false, latencyCritical: false)
                hud.showSuccess(text: "Clipboard queue complete")
            } else {
                clipboardQueueIndicator.show(mode: mode, count: count)
            }
        case .captureRejected:
            markRuntimeActivity(preconnect: false, latencyCritical: true)
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
        if (clipboardQueueServiceStorage?.mode ?? .inactive) != .inactive {
            clipboardQueueServiceStorage?.deactivate(notify: false)
            clipboardQueueIndicatorStorage?.dismiss()
        }
        guard inputLockService.activate(mode) else {
            hud.showError("Input Lock could not start · check Accessibility permission")
            return
        }
        inputLockIndicator.show(mode: mode)
    }

    private func deactivateInputLock(showFeedback: Bool) {
        guard inputLockServiceStorage?.mode != nil else {
            return
        }
        markRuntimeActivity(preconnect: false, latencyCritical: showFeedback)
        inputLockServiceStorage?.deactivate()
        inputLockIndicatorStorage?.dismiss()
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
            let completion = try await callAPI(prompt: prompt, imagePNGs: [capture.pngData])
            guard !completion.output.isEmpty else {
                lastAPIStatus = "No OCR text"
                hud.showError("No readable text found")
                return
            }
            // OCR is deliberately literal: keep its pasteboard representation
            // to plain text even though other AI outputs may be rich.
            selectionService.placeOnClipboard(completion.output.source)
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

            let panel = promptPanel ?? PromptPanelController()
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
                self.activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
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

        do {
            let completion = try await callAPI(prompt: prompt, imagePNGs: [capture.pngData])
            guard !completion.output.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            let rendered = richTextRenderer.render(completion.output)
            selectionService.placeOnClipboard(rendered.clipboardPayload)
            hud.showResult(rendered: rendered)
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

        let panel = promptPanel ?? PromptPanelController()
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
            self.activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
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

        do {
            let completion = try await callAPI(prompt: prompt)
            guard !completion.output.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            let rendered = richTextRenderer.render(completion.output)
            if action == .translate {
                selectionService.placeOnClipboard(rendered.clipboardPayload)
                hud.showSuccess(text: "Translation copied")
            } else {
                let replaced = await selectionService.replaceIfUnchanged(
                    snapshot,
                    with: rendered.clipboardPayload,
                    preferAccessibility: completion.output.format == .plainText
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
        activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
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

        do {
            let completion = try await callAPI(prompt: prompt, imagePNGs: imagePNGs)
            guard !completion.output.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            explanationMemory.record(
                highlightedText: snapshot?.text ?? "",
                request: Self.explanationDisplayRequest(request, imageCount: imagePNGs.count),
                explanation: completion.output
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

    private func callAPI(
        prompt: PromptSpec,
        imagePNGs: [Data] = []
    ) async throws -> AICompletion {
        guard let apiKey else {
            throw KeySourceError.missingKey
        }
        let configuration = stateStore.aiProviderConfiguration(for: stateStore.aiProvider)
        let start = Date()
        do {
            let completion = try await apiClient.complete(
                prompt: prompt,
                imagePNGs: imagePNGs,
                apiKey: apiKey,
                safetyIdentifier: cachedSafetyIdentifier,
                configuration: configuration
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
                return "The AI provider took too long — press Enter to retry."
            default:
                return "The AI provider connection failed — press Enter to retry."
            }
        }
        return error.localizedDescription
    }

    private func beginOperation(_ action: AIShortcutAction) {
        resourceTrimWorkItem?.cancel()
        resourceTrimWorkItem = nil
        idleSleepWorkItem?.cancel()
        idleSleepWorkItem = nil
        beginLatencyActivity()
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
        scheduleLatencyActivityEnd(after: 0.5)
        scheduleResourceTrim()
        scheduleIdleSleep()
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
        screenshotServiceStorage?.cancelCapture()

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

    private static func explanationDisplayRequest(_ request: String, imageCount: Int) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageCount > 0 else {
            return trimmed
        }
        let label = imageCount == 1 ? "Image attached" : "\(imageCount) images attached"
        return trimmed.isEmpty ? label : "\(trimmed)\n\(label)"
    }
}
