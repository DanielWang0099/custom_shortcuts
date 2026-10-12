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

    // Keep shortcut resources resident so the first action after idle has the
    // same preparation path as a recently used action.
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
    private var dictionaryCoordinatorStorage: DictionaryCoordinator?
    private var inputLockIndicatorStorage: InputLockIndicatorController?
    private var clipboardQueueIndicatorStorage: ClipboardQueueIndicatorController?
    private var welcomeWindowStorage: WelcomeWindowController?
    private var inputLockServiceStorage: InputLockService?
    private var clipboardQueueServiceStorage: ClipboardQueueService?
    private var chromeVoiceServiceStorage: ChromeVoiceSessionService?

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
    private var networkKeepaliveWorkItem: DispatchWorkItem?
    private var latencyActivityEndWorkItem: DispatchWorkItem?
    private var latencyActivity: NSObjectProtocol?
    private var networkPreconnectTask: Task<Void, Never>?
    private var preconnectGeneration = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private static let networkKeepaliveInterval: TimeInterval = 60
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

    private var chromeVoiceService: ChromeVoiceSessionService {
        if let chromeVoiceServiceStorage {
            return chromeVoiceServiceStorage
        }
        let service = ChromeVoiceSessionService()
        chromeVoiceServiceStorage = service
        return service
    }

    private var dictionaryCoordinator: DictionaryCoordinator {
        if let dictionaryCoordinatorStorage {
            return dictionaryCoordinatorStorage
        }
        let coordinator = DictionaryCoordinator(
            stateStore: stateStore,
            selectionService: selectionService,
            aiCompletion: makeDictionaryAICompletion(),
            onOpenPermissionSettings: { [weak self] in
                self?.openDictionaryPermissionSettings()
            }
        )
        dictionaryCoordinatorStorage = coordinator
        return coordinator
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
        prewarmPrimaryResources()
        prewarmSecondaryResources()
        refreshFinderAutomationAuthorization()
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
        if let coordinator = dictionaryCoordinatorStorage,
           DictionaryActivationPolicy.shouldSkipOnboarding(
               consumePanelActivation: coordinator.consumePanelActivation,
               hasActiveWork: { coordinator.hasActiveWork }
           )
        {
            return
        }
        continueOnboarding()
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkKeepaliveWorkItem?.cancel()
        latencyActivityEndWorkItem?.cancel()
        networkPreconnectTask?.cancel()
        memoryPressureSource?.cancel()
        dictionaryCoordinatorStorage?.releaseResources()
        apiClient.suspendConnection()
        endLatencyActivity()
        hotKeyManager?.invalidate()

        inputLockServiceStorage?.deactivate()
        inputLockIndicatorStorage?.dismiss()
        clipboardQueueServiceStorage?.deactivate(notify: false)
        clipboardQueueIndicatorStorage?.dismiss()
        chromeVoiceServiceStorage?.invalidate()

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
            self?.releaseResourcesUnderMemoryPressure()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func prewarmPrimaryResources() {
        let start = Date()
        _ = selectionService
        _ = screenshotService
        _ = richTextRenderer
        hud.prepare()
        if promptPanel == nil {
            promptPanel = PromptPanelController()
        }
        let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
        logger.notice("Prewarmed primary shortcut resources in \(milliseconds, privacy: .public) ms.")
    }

    private func prewarmSecondaryResources() {
        let start = Date()
        explanationPanel.prepare()
        finderService.prepare()
        _ = insertLibrary
        _ = insertPanel
        _ = inputLockService
        _ = inputLockPanel
        _ = inputLockIndicator
        _ = clipboardQueueService
        _ = clipboardQueueIndicator
        _ = chromeVoiceService
        _ = dictionaryCoordinator
        _ = modelSettings
        _ = shortcutGuide
        let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
        logger.notice("Prewarmed secondary shortcut resources in \(milliseconds, privacy: .public) ms.")
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
        case .chatgptVoice:
            _ = chromeVoiceService
        case .dictionary:
            _ = dictionaryCoordinator
        }
    }

    private func markRuntimeActivity(
        preconnect: Bool,
        latencyCritical: Bool
    ) {
        if latencyCritical {
            beginLatencyActivity()
            scheduleLatencyActivityEnd()
        }
        if preconnect, apiKey != nil {
            apiClient.prepareConnection()
            startNetworkPreconnectionIfNeeded()
        }
        scheduleNetworkKeepalive()
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

    private func scheduleNetworkKeepalive() {
        networkKeepaliveWorkItem?.cancel()
        guard apiKey != nil else {
            networkKeepaliveWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.networkKeepaliveWorkItem = nil
            if !self.isBusy {
                self.apiClient.prepareConnection()
                self.startNetworkPreconnectionIfNeeded()
            }
            self.scheduleNetworkKeepalive()
        }
        networkKeepaliveWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.networkKeepaliveInterval,
            execute: workItem
        )
    }

    private func suspendNetworkResidency() {
        networkKeepaliveWorkItem?.cancel()
        networkKeepaliveWorkItem = nil
        preconnectGeneration &+= 1
        networkPreconnectTask?.cancel()
        networkPreconnectTask = nil
        apiClient.suspendConnection()
        endLatencyActivity()
    }

    private func releaseResourcesUnderMemoryPressure() {
        releaseDormantResources()
        releaseAllocatorPages()
        logger.notice("Released dormant resources under memory pressure.")
    }

    private func releaseAllocatorPages() {
        // Return allocator pages only when macOS reports memory pressure.
        DispatchQueue.global(qos: .utility).async {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
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
        if dictionaryCoordinatorStorage?.hasActiveWork != true {
            dictionaryCoordinatorStorage?.releaseResources()
            dictionaryCoordinatorStorage = nil
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
            refreshDictionaryAICompletion()
            suspendNetworkResidency()
            markRuntimeActivity(preconnect: true, latencyCritical: false)
            hud.showSuccess(text: "Model settings saved")
        } catch {
            self.apiKey = nil
            refreshDictionaryAICompletion()
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
            refreshDictionaryAICompletion()
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
            refreshDictionaryAICompletion()
            suspendNetworkResidency()
            markRuntimeActivity(preconnect: true, latencyCritical: false)
            if showFeedback {
                hud.showSuccess(text: "API key loaded")
            }
            return true
        } catch {
            apiKey = nil
            refreshDictionaryAICompletion()
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
        if action == .dictionary {
            guard !isBusy || dictionaryCoordinator.isVisible else {
                hud.showBusy()
                return
            }
            dictionaryCoordinator.toggle()
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
        case .chatgptVoice:
            let generation = operationGeneration
            activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.runChatGPTVoice(generation: generation)
            }
        case .inputLock:
            break
        case .clipboardQueue:
            break
        case .insert:
            break
        case .dictionary:
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
                if action == .chatgptVoice {
                    chromeVoiceServiceStorage?.invalidate()
                }
                if action == .dictionary {
                    dictionaryCoordinatorStorage?.cancel(dismissPanel: true)
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
            },
            onCancel: { [weak self] in
                guard let self, self.currentAction == .insert else { return }
                self.cancelCurrentOperation(showFeedback: false)
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
            guard !Task.isCancelled, insertPanel.isVisible else { return }
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
            if selectionService.placeOnClipboard(entry.value) {
                hud.showError("Could not return to the original field · value copied")
            } else {
                hud.showError("Could not paste or update the clipboard")
            }
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
            guard selectionService.placeOnClipboard(completion.output.source) else {
                hud.showError("OCR finished but the clipboard update failed")
                return
            }
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
            guard selectionService.placeOnClipboard(rendered.clipboardPayload) else {
                hud.showError("Calculation finished but the clipboard update failed")
                return
            }
            hud.showResult(rendered: rendered)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            handleOperationError(error, action: .calculate)
        }
    }

    private func runChatGPTVoice(generation: Int) async {
        // A cancelled launch can finish after another shortcut has started.
        // Only this operation may release its own busy state or show feedback.
        defer {
            if operationGeneration == generation, currentAction == .chatgptVoice {
                finishOperation()
            }
        }
        do {
            let outcome = try await chromeVoiceService.startOrResume()
            guard !Task.isCancelled,
                  operationGeneration == generation,
                  currentAction == .chatgptVoice else {
                return
            }
            let message: String
            switch outcome {
            case .startedNew:
                message = "ChatGPT voice started · new chat"
            case .resumed:
                message = "ChatGPT voice resumed"
            case .alreadyActive:
                message = "ChatGPT voice is already active"
            }
            hud.showSuccess(text: message)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  operationGeneration == generation,
                  currentAction == .chatgptVoice else {
                return
            }
            if let voiceError = error as? ChromeVoiceError,
               case .automationDenied = voiceError {
                requestAutomationPermission(openSettings: true)
                hud.showError("Chrome access is off · Privacy & Security → Automation")
            } else {
                hud.showError(error.localizedDescription)
            }
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
            guard selectionService.placeOnClipboard(joined) else {
                hud.showError("Could not update the clipboard")
                return
            }
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

    private func openDictionaryPermissionSettings() {
        NSWorkspace.shared.open(AppConfiguration.accessibilitySettingsURL)
    }

    private func captureAndRunTextAction(_ action: AIShortcutAction) async {
        let captureStart = Date()
        guard let snapshot = await selectionService.captureSelection() else {
            hud.showError("Select some text first")
            finishOperation()
            return
        }
        let captureMilliseconds = Int(Date().timeIntervalSince(captureStart) * 1_000)
        logger.notice(
            "Captured \(action.displayName, privacy: .public) selection in \(captureMilliseconds, privacy: .public) ms."
        )
        await runTextAction(action, snapshot: snapshot, parameter: nil)
    }

    private func captureAndRequestParameter(for action: AIShortcutAction) async {
        let preparationStart = Date()
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
            guard let parameter else {
                self.finishOperation()
                return
            }
            self.activeTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let replacementEligible = await self.selectionService.reactivate(snapshot)
                guard !Task.isCancelled else {
                    self.finishOperation()
                    return
                }
                await self.runTextAction(
                    action,
                    snapshot: snapshot,
                    parameter: parameter,
                    replacementEligible: replacementEligible
                )
            }
        }
        let preparationMilliseconds = Int(Date().timeIntervalSince(preparationStart) * 1_000)
        logger.notice(
            "Prepared \(action.displayName, privacy: .public) prompt in \(preparationMilliseconds, privacy: .public) ms."
        )
    }

    private func runTextAction(
        _ action: AIShortcutAction,
        snapshot: SelectionSnapshot,
        parameter: String?,
        replacementEligible: Bool = true
    ) async {
        defer { finishOperation() }
        let prompt = PromptBuilder.make(
            action: action,
            selectedText: snapshot.text,
            parameter: parameter
        )

        do {
            let completion = try await callAPI(prompt: prompt)
            let postResponseStart = Date()
            guard !completion.output.isEmpty else {
                throw ResponsesAPIError.missingOutput
            }
            let boundaryMatched = SelectionOutputPolicy.matchSelectionBoundary(
                originalSelection: snapshot.text,
                output: completion.output.source
            )
            let targetScript = action == .translate
                ? ChineseScript.instruction(parameter ?? "")?.script : nil
            let deliveredSource = targetScript?.convertProse(boundaryMatched) ?? boundaryMatched
            let boundaryMatchedOutput = AIOutputDocument(
                format: completion.output.format,
                source: deliveredSource,
                preserveTrailingLineBreaks: true
            )
            let rendered = richTextRenderer.render(boundaryMatchedOutput)
            guard !rendered.clipboardPayload.plainText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ResponsesAPIError.invalidOutput(
                    "The AI provider returned an empty answer."
                )
            }

            let delivery: SelectionDeliveryOutcome
            if replacementEligible,
               SelectionReplacementPolicy.shouldAttemptReplacement(for: action)
            {
                delivery = await selectionService.replaceIfUnchanged(
                    snapshot,
                    with: rendered.clipboardPayload,
                    preferAccessibility: completion.output.format == .plainText
                )
            } else if selectionService.placeOnClipboard(rendered.clipboardPayload) {
                delivery = .copied
            } else {
                delivery = .clipboardFailed
            }

            let outcome: String
            switch action {
            case .refine:
                outcome = "Refined"
            case .translate:
                outcome = "Translated"
            case .format:
                outcome = "Formatted"
            default:
                outcome = action.displayName
            }
            switch delivery {
            case .replaced:
                hud.showSuccess(text: "\(outcome) · replaced")
            case .replacementSent:
                hud.showSuccess(text: "\(outcome) · replace sent + copied")
            case .copied:
                hud.showSuccess(text: "\(outcome) · copied")
            case .clipboardFailed:
                hud.showError("\(outcome) but could not update the clipboard")
            }
            let postResponseMilliseconds = Int(
                Date().timeIntervalSince(postResponseStart) * 1_000
            )
            logger.notice(
                "Handled \(action.displayName, privacy: .public) response in \(postResponseMilliseconds, privacy: .public) ms."
            )
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

    private func completeDictionary(
        _ request: DictionaryAIRequest
    ) async throws -> DictionaryAIResponse {
        guard let apiKey else {
            throw KeySourceError.missingKey
        }
        let configuration = stateStore.aiProviderConfiguration(for: stateStore.aiProvider)
        do {
            let response = try await apiClient.completeDictionary(
                request: request,
                apiKey: apiKey,
                safetyIdentifier: cachedSafetyIdentifier,
                configuration: configuration
            )
            lastAPIStatus = "Success"
            return response
        } catch {
            lastAPIStatus = "Error"
            throw error
        }
    }

    /// Dictionary's native/API lookup remains usable without an AI key. Keep
    /// the optional completion absent until a key is loaded so a successful
    /// basic lookup does not manufacture a missing-key error for enrichment.
    private func makeDictionaryAICompletion() -> DictionaryCoordinator.AICompletion? {
        guard apiKey != nil else {
            return nil
        }
        return { [weak self] request in
            guard let self else {
                throw KeySourceError.missingKey
            }
            return try await self.completeDictionary(request)
        }
    }

    private func refreshDictionaryAICompletion() {
        dictionaryCoordinatorStorage?.setAICompletion(makeDictionaryAICompletion())
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
        hudStorage?.dismissBusy()
        scheduleLatencyActivityEnd(after: 0.5)
        scheduleNetworkKeepalive()
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

        promptPanel?.cancel()

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
