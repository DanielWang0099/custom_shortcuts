import AppKit
import ApplicationServices
import AIShortcutsCore
import CoreServices
import Foundation

/// AppDelegate must check this pending presentation token before inspecting
/// active work. During `present`, `NSApp.activate` can synchronously deliver
/// `applicationDidBecomeActive` before the panel is ordered front and before
/// lookup/context tasks are assigned.
@MainActor
enum DictionaryActivationPolicy {
    static func shouldSkipOnboarding(
        consumePanelActivation: @MainActor () -> Bool,
        hasActiveWork: @MainActor () -> Bool
    ) -> Bool {
        if consumePanelActivation() {
            return true
        }
        return hasActiveWork()
    }
}

enum DictionaryToggleDisposition: Equatable {
    case activateVisiblePanel
    case dismissVisiblePanel
    case startCapture
    case ignorePendingCapture
}

enum DictionaryTogglePolicy {
    static func disposition(
        panelVisible: Bool,
        panelIsKey: Bool,
        appIsActive: Bool,
        captureInFlight: Bool
    ) -> DictionaryToggleDisposition {
        if captureInFlight {
            return .ignorePendingCapture
        }
        if panelVisible {
            return appIsActive && panelIsKey ? .dismissVisiblePanel : .activateVisiblePanel
        }
        return .startCapture
    }
}

/// Coordinates Dictionary's selected-text capture, native results, structured
/// dictionary lookups, and optional AI enrichment. Dictionary work deliberately
/// has its own lifecycle: a slow network request must never hold the global
/// shortcut operation lock used by the other actions.
@MainActor
final class DictionaryCoordinator {
    struct CaptureDependencies {
        let accessibilityTrusted: @MainActor () -> Bool
        let selectedText: @MainActor () async -> String?

        static func live(selectionService: SelectionService) -> Self {
            Self(
                accessibilityTrusted: { AXIsProcessTrusted() },
                selectedText: {
                    guard AXIsProcessTrusted() else {
                        return nil
                    }
                    return await selectionService
                        .captureSelection(preserveClipboard: true)?
                        .text
                }
            )
        }

        init(
            accessibilityTrusted: @escaping @MainActor () -> Bool,
            selectedText: @escaping @MainActor () async -> String?
        ) {
            self.accessibilityTrusted = accessibilityTrusted
            self.selectedText = selectedText
        }
    }

    typealias AICompletion = @MainActor (
        DictionaryAIRequest
    ) async throws -> DictionaryAIResponse

    /// Optional off-main-actor hook used by native checks. Production uses
    /// Dictionary Services refinement with a larger bounded probe budget;
    /// keeping the hook injectable makes cancellation and AI-precedence races
    /// deterministic without changing the capture or lookup transports.
    typealias NativeRefinement = @Sendable (
        [DictionaryNativeToken]
    ) async -> [DictionaryNativeToken]

    private let stateStore: AppStateStore
    private let panel: DictionaryPanelController
    private let lookupService: DictionaryLookupService
    private let speechService: DictionarySpeechService
    private let historyStore: DictionaryHistoryStore
    private let captureDependencies: CaptureDependencies
    private var aiCompletion: AICompletion?
    private let nativeRefinement: NativeRefinement?
    private let onOpenPermissionSettings: @MainActor () -> Void
    private let wholeInputWordProbe: @MainActor (String, DictionarySourceLanguage) -> Bool

    private var captureTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var nativeRefinementTask: Task<Void, Never>?
    private var prefetchTasks: [Task<Void, Never>] = []
    private var generation = 0
    private var wordGeneration = 0

    private var query = ""
    /// The source language selected by the user. Automatic detection is kept
    /// separate from the resolved language used by lookup requests.
    private var sourceOverride: DictionarySourceLanguage = .automatic
    private var sourceLanguage: DictionarySourceLanguage = .automatic
    private var targetLanguage: DictionaryTargetLanguage
    private var mode: DictionaryPanelMode = .manual
    private var presentationMode: DictionaryPresentationMode
    private var paragraphTranslation: String?
    private var sentenceTokens: [DictionaryPanelToken] = []
    private var activeToken: DictionaryPanelToken?
    private var sentenceTranslation: String?
    private var currentWord: DictionaryPanelWord?
    private var currentAIAdditions: [String] = []
    private var currentError: String?
    private var contextError: String?
    private var aiSegmentationApplied = false
    private var nativeRefinementApplied = false
    private var historyError: String?
    private var lastCaptureNotice: String?
    private var phraseSelectionRange: NSRange?

    private var cachedLookups: [String: DictionaryLookupResult] = [:]
    private var inFlightLookups: [String: Task<DictionaryLookupResult, Error>] = [:]
    private var inFlightLookupIDs: [String: UUID] = [:]
    private var sentenceTranslations: [String: String] = [:]
    private var paragraphTranslations: [String: String] = [:]
    private var cachedEnrichments: [String: DictionaryAIResponse] = [:]
    private var inFlightEnrichments: [String: Task<DictionaryAIResponse, Error>] = [:]
    private var inFlightEnrichmentIDs: [String: UUID] = [:]
    private var panelActivationDeadline: Date?

    var isVisible: Bool {
        panel.isVisible
    }

    /// A Dictionary capture or lookup can activate the accessory app in order
    /// to show its panel. AppDelegate uses this to avoid treating that panel
    /// activation as a fresh onboarding event.
    var hasActiveWork: Bool {
        panel.isVisible
            || captureTask != nil
            || lookupTask != nil
            || contextTask != nil
            || enrichmentTask != nil
    }

    func consumePanelActivation() -> Bool {
        guard let deadline = panelActivationDeadline else { return false }
        panelActivationDeadline = nil
        return Date() <= deadline
    }

    init(
        stateStore: AppStateStore,
        selectionService: SelectionService,
        panel: DictionaryPanelController = DictionaryPanelController(),
        lookupService: DictionaryLookupService = DictionaryLookupService(),
        speechService: DictionarySpeechService = .shared,
        historyStore: DictionaryHistoryStore = DictionaryHistoryStore(),
        captureDependencies: CaptureDependencies? = nil,
        aiCompletion: AICompletion? = nil,
        nativeRefinement: NativeRefinement? = nil,
        onOpenPermissionSettings: @escaping @MainActor () -> Void = {},
        wholeInputWordProbe: @escaping @MainActor (String, DictionarySourceLanguage) -> Bool = {
            query,
            language in
            DictionaryCoordinator.nativeWholeInputWordProbe(query, language: language)
        }
    ) {
        self.stateStore = stateStore
        self.panel = panel
        self.lookupService = lookupService
        self.speechService = speechService
        self.historyStore = historyStore
        self.captureDependencies = captureDependencies ?? .live(
            selectionService: selectionService
        )
        self.aiCompletion = aiCompletion
        self.nativeRefinement = nativeRefinement
        self.wholeInputWordProbe = wholeInputWordProbe
        self.targetLanguage = DictionaryTargetLanguage(
            rawValue: stateStore.dictionaryTargetLanguage
        ) ?? .english
        self.presentationMode = stateStore.dictionaryPresentationMode
        self.onOpenPermissionSettings = onOpenPermissionSettings
        // Loading is synchronous in the bounded store initializer. Preserve
        // a read/malformed-file failure so the panel can expose it alongside
        // the current lookup rather than silently dropping the history error.
        self.historyError = historyStore.storageError?.localizedDescription
    }

    func setAICompletion(_ completion: AICompletion?) {
        if presentationMode == .translate, panel.isVisible {
            cancelAllTasks()
            generation &+= 1
        }
        aiCompletion = completion
        if presentationMode == .translate, panel.isVisible {
            startParagraphTranslation(generation: generation)
        }
    }

    func toggle() {
        switch DictionaryTogglePolicy.disposition(
            panelVisible: panel.isVisible,
            panelIsKey: panel.isKeyWindow,
            appIsActive: NSApp.isActive,
            captureInFlight: captureTask != nil
        ) {
        case .activateVisiblePanel:
            refreshSelectionBeforeBringingForward()
        case .dismissVisiblePanel:
            cancel(dismissPanel: true)
        case .ignorePendingCapture:
            // Capture can take a short time (especially when the source app
            // must service Copy). A repeated activation must not cancel and
            // restart the first capture before it can present the panel.
            return
        case .startCapture:
            start()
        }
    }

    private func refreshSelectionBeforeBringingForward() {
        let requestGeneration = generation
        // Keep the source application focused until Copy has completed. Taking
        // focus first would capture Dictionary's field rather than the new
        // selection in an Electron application or browser.
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let selected = self.captureDependencies.accessibilityTrusted()
                ? await self.captureDependencies.selectedText() : nil
            guard self.generation == requestGeneration, !Task.isCancelled else { return }
            self.captureTask = nil
            if let selected, SelectionCapturePolicy.containsMeaningfulText(selected) {
                self.sourceOverride = .automatic
                self.beginLookup(for: selected, generation: requestGeneration)
            } else {
                self.reopenLatestHistoryOrManual(generation: requestGeneration)
            }
            // Activate only after capture has finished in the source app.
            if !NSApp.isActive {
                self.panelActivationDeadline = Date().addingTimeInterval(1)
            }
            self.panel.bringForward()
        }
    }

    func start() {
        cancel(dismissPanel: false)
        resetContext()
        captureTask = Task { @MainActor [weak self] in
            await self?.runSelectionCapture()
        }
    }

    /// Cancels capture, lookup, sentence translation, and focused enrichment.
    /// Incrementing the generation makes already-returned async values stale
    /// even when an underlying transport cannot be interrupted immediately.
    func cancel(dismissPanel: Bool = true) {
        generation &+= 1
        wordGeneration &+= 1
        captureTask?.cancel()
        lookupTask?.cancel()
        contextTask?.cancel()
        enrichmentTask?.cancel()
        nativeRefinementTask?.cancel()
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        inFlightLookups.values.forEach { $0.cancel() }
        inFlightLookups.removeAll()
        inFlightLookupIDs.removeAll()
        inFlightEnrichments.values.forEach { $0.cancel() }
        inFlightEnrichments.removeAll()
        inFlightEnrichmentIDs.removeAll()
        captureTask = nil
        lookupTask = nil
        contextTask = nil
        enrichmentTask = nil
        nativeRefinementTask = nil
        panelActivationDeadline = nil
        if dismissPanel, panel.isVisible {
            panel.dismiss()
        }
        speechService.stop()
    }

    func releaseResources() {
        cancel(dismissPanel: true)
        panel.releaseResources()
    }

    // MARK: Selection capture

    private func runSelectionCapture() async {
        let requestGeneration = generation
        defer {
            if generation == requestGeneration {
                captureTask = nil
            }
        }

        let accessibilityGranted = captureDependencies.accessibilityTrusted()
        if accessibilityGranted {
            let selected = await captureDependencies.selectedText()
            guard generation == requestGeneration, !Task.isCancelled else {
                return
            }
            if let selected,
               SelectionCapturePolicy.containsMeaningfulText(selected)
            {
                beginLookup(for: selected, generation: requestGeneration)
                return
            }
        }

        reopenLatestHistoryOrManual(generation: requestGeneration)
    }

    private func reopenLatestHistoryOrManual(generation requestGeneration: Int) {
        guard generation == requestGeneration, !Task.isCancelled else { return }
        if let latest = panelHistoryItems().first {
            restoreHistory(latest)
            return
        }
        showManual(
            notice: captureDependencies.accessibilityTrusted()
                ? "Type a word or sentence to look up."
                : "Selected-text capture needs Accessibility permission. Type below or open capture settings.",
            generation: requestGeneration
        )
    }

    private func showManual(notice: String, generation requestGeneration: Int) {
        guard generation == requestGeneration, !Task.isCancelled else {
            return
        }
        panel.prepareForNewLookup()
        query = ""
        phraseSelectionRange = nil
        mode = .manual
        sentenceTokens.removeAll()
        activeToken = nil
        sentenceTranslation = nil
        paragraphTranslation = nil
        currentWord = nil
        currentAIAdditions.removeAll()
        currentError = nil
        contextError = nil
        lastCaptureNotice = notice
        present(
            state: makeState(isLoading: false, notice: notice),
            focusInput: true
        )
    }

    // MARK: Lookup lifecycle

    private func beginLookup(
        for rawQuery: String,
        generation requestGeneration: Int? = nil,
        recordHistory shouldRecordHistory: Bool = true
    ) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestGeneration, generation != requestGeneration {
            return
        }
        guard !trimmed.isEmpty else {
            // Clearing the field is a lifecycle event, too. Invalidate every
            // in-flight result before showing manual input so a late response
            // cannot restore the old query or add stale AI content.
            cancelAllTasks()
            generation &+= 1
            wordGeneration &+= 1
            showManual(
                notice: lastCaptureNotice ?? "Type a word or sentence to look up.",
                generation: generation
            )
            return
        }

        cancelAllTasks()
        generation &+= 1
        wordGeneration &+= 1
        let lookupGeneration = generation
        panel.prepareForNewLookup()
        query = rawQuery
        phraseSelectionRange = nil
        currentError = nil
        contextError = nil
        aiSegmentationApplied = false
        nativeRefinementApplied = false
        historyError = historyStore.storageError?.localizedDescription
        currentAIAdditions.removeAll()
        sentenceTranslation = nil
        currentWord = nil
        sourceLanguage = DictionaryLanguageService.detect(
            rawQuery,
            preferred: sourceOverride
        )

        if presentationMode == .translate {
            resolveParagraphTargetLanguage()
            mode = .manual
            sentenceTokens.removeAll()
            activeToken = nil
            paragraphTranslation = nil
            if shouldRecordHistory { recordHistory(for: rawQuery) }
            present(state: makeState(isLoading: aiCompletion != nil), focusInput: false)
            startParagraphTranslation(generation: lookupGeneration)
            return
        }

        // Automatic mode must remain automatic while tokenizing.  Passing the
        // sentence's dominant language here would stamp a mixed-script query
        // (for example an English filename containing 参考) as all-English.
        // An explicit source override intentionally keeps the whole query in
        // that selected language.
        let nativeTokens = DictionaryLanguageService.tokenize(
            rawQuery,
            language: sourceOverride
        )
        sentenceTokens = nativeTokens.map(DictionaryPanelToken.init(native:))
        mode = Self.isWholeInputWord(
            rawQuery,
            sourceLanguage: sourceLanguage,
            wordTokens: nativeTokens,
            probe: wholeInputWordProbe
        ) ? .word : .sentence
        activeToken = mode == .sentence
            ? sentenceTokens.first(where: { $0.isWordToken })
            : nil

        if shouldRecordHistory {
            recordHistory(for: rawQuery)
        }

        present(
            state: makeState(isLoading: true),
            focusInput: false
        )

        if mode == .sentence {
            startSentenceContext(generation: lookupGeneration)
        }
        startActiveLookup(generation: lookupGeneration)
        if mode == .sentence {
            startNativeRefinement(
                generation: lookupGeneration,
                initialTokens: nativeTokens
            )
        }
    }

    private func startActiveLookup(generation lookupGeneration: Int) {
        let token: DictionaryPanelToken?
        if mode == .word {
            // Whole-input CJK terms can be classified as dictionary words even
            // when NLTokenizer split them into smaller Han tokens (for
            // example, 你好 or 图书馆). Build the lookup token from the query
            // itself so the transport receives the complete term. Reuse a
            // lemma only when native tokenization produced one token covering
            // the entire input; never borrow the first fragment of a split
            // CJK term.
            token = wholeInputWordToken()
        } else if let activeToken {
            token = activeToken
        } else {
            token = nil
        }
        guard let word = token?.headword
            ?? token?.text
            ?? (mode == .word ? query : nil),
              !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            finishWithoutWord(generation: lookupGeneration, message: "Choose a word to look up.")
            return
        }
        let surfaceFallback = token?.headword != nil && token?.headword != token?.text
            ? token?.text
            : nil

        let source = resolvedSourceLanguage(for: token)
        let target = targetLanguage
        let sentence = query
        let currentWordGeneration = wordGeneration
        lookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadActiveWord(
                word: word,
                surfaceFallback: surfaceFallback,
                sourceLanguage: source,
                targetLanguage: target,
                sentence: sentence,
                token: token,
                generation: lookupGeneration,
                wordGeneration: currentWordGeneration
            )
        }
    }

    private func wholeInputWordToken() -> DictionaryPanelToken? {
        guard !query.isEmpty else { return nil }
        let fullRange = NSRange(
            location: 0,
            length: (query as NSString).length
        )
        let nativeWholeToken = sentenceTokens.first(where: {
            $0.isWordToken && $0.utf16Range == fullRange
        })
        return DictionaryPanelToken(
            text: query,
            utf16Range: fullRange,
            headword: nativeWholeToken?.headword ?? query,
            sourceLanguage: resolvedSourceLanguage(for: nativeWholeToken),
            isPunctuation: false,
            isWhitespace: false
        )
    }

    private func loadActiveWord(
        word: String,
        surfaceFallback: String?,
        sourceLanguage: DictionarySourceLanguage,
        targetLanguage: DictionaryTargetLanguage,
        sentence: String,
        token: DictionaryPanelToken?,
        generation lookupGeneration: Int,
        wordGeneration lookupWordGeneration: Int
    ) async {
        defer {
            if generation == lookupGeneration,
               wordGeneration == lookupWordGeneration
            {
                lookupTask = nil
                if mode == .sentence, !Task.isCancelled {
                    // The active request owns the first network/cache turn.
                    // Only start adjacent prefetch after every active path
                    // (cache, native, API, or error) has finished.
                    prefetchAdjacentEntries(generation: lookupGeneration)
                }
            }
        }

        // Show a previously persisted API result before consulting native
        // Dictionary Services or starting a network request. The actor owns
        // the bounded on-disk cache; this small in-memory layer also avoids
        // repeatedly crossing the actor boundary while navigating tokens.
        let cacheKey = Self.lookupCacheKey(
            word: word,
            sourceLanguage: sourceLanguage
        )
        if let cached = cachedLookups[cacheKey] {
            applyStructuredResult(
                cached,
                word: word,
                surfaceFallback: surfaceFallback,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sentence: sentence,
                token: token,
                native: nil,
                generation: lookupGeneration,
                wordGeneration: lookupWordGeneration
            )
            return
        }
        if let cached = await lookupService.cachedLookup(
            language: Self.coreLanguage(sourceLanguage),
            word: word
        ) {
            guard generation == lookupGeneration,
                  wordGeneration == lookupWordGeneration,
                  !Task.isCancelled
            else {
                return
            }
            cacheLookup(cached, for: cacheKey)
            applyStructuredResult(
                cached,
                word: word,
                surfaceFallback: surfaceFallback,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sentence: sentence,
                token: token,
                native: nil,
                generation: lookupGeneration,
                wordGeneration: lookupWordGeneration
            )
            return
        }

        let native = try? await DictionaryNativeLookupService.lookup(
            word,
            sourceLanguage: sourceLanguage
        )
        guard generation == lookupGeneration,
              wordGeneration == lookupWordGeneration,
              !Task.isCancelled
        else {
            return
        }
        if let native {
            currentWord = Self.panelWord(
                originalText: token?.text ?? word,
                native: native,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            currentError = nil
            present(state: makeState(isLoading: true), focusInput: false)
        }

        do {
            let result = try await lookup(
                word: word,
                sourceLanguage: sourceLanguage
            )
            guard generation == lookupGeneration,
                  wordGeneration == lookupWordGeneration,
                  !Task.isCancelled
            else {
                return
            }
            if let surfaceFallback,
               Self.preferredEntry(in: result) == nil
            {
                do {
                    let fallbackResult = try await lookup(
                        word: surfaceFallback,
                        sourceLanguage: sourceLanguage
                    )
                    guard generation == lookupGeneration,
                          wordGeneration == lookupWordGeneration,
                          !Task.isCancelled
                    else {
                        return
                    }
                    applyStructuredResult(
                        fallbackResult,
                        word: surfaceFallback,
                        surfaceFallback: nil,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        sentence: sentence,
                        token: token,
                        native: native,
                        generation: lookupGeneration,
                        wordGeneration: lookupWordGeneration
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // Preserve the original miss/error below when the
                    // surface-form retry is unavailable as well.
                }
            }
            applyStructuredResult(
                result,
                word: word,
                surfaceFallback: surfaceFallback,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sentence: sentence,
                token: token,
                native: native,
                generation: lookupGeneration,
                wordGeneration: lookupWordGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == lookupGeneration,
                  wordGeneration == lookupWordGeneration,
                  !Task.isCancelled
            else {
                return
            }
            // Native Dictionary Services are useful offline and should remain
            // visible while a non-blocking retry/error status is shown. An
            // empty online response is not an error for a usable native
            // definition; avoid showing a contradictory "no entry" banner
            // over that definition. Transport and service errors still keep
            // the retry status visible.
            let isNoEntry = (error as? DictionaryAPIError) == .noEntries
            currentError = (native != nil && isNoEntry)
                ? nil
                : error.localizedDescription
            if let surfaceFallback {
                do {
                    let fallbackResult = try await lookup(
                        word: surfaceFallback,
                        sourceLanguage: sourceLanguage
                    )
                    guard generation == lookupGeneration,
                          wordGeneration == lookupWordGeneration,
                          !Task.isCancelled
                    else {
                        return
                    }
                    applyStructuredResult(
                        fallbackResult,
                        word: surfaceFallback,
                        surfaceFallback: nil,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        sentence: sentence,
                        token: token,
                        native: native,
                        generation: lookupGeneration,
                        wordGeneration: lookupWordGeneration
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the original network error visible below.
                }
            }
            if let aiCompletion {
                let fallbackWord = surfaceFallback ?? word
                let synthetic = Self.syntheticEntry(
                    word: fallbackWord,
                    sourceLanguage: sourceLanguage,
                    native: native
                )
                if native == nil {
                    currentWord = Self.syntheticPanelWord(
                        originalText: token?.text ?? fallbackWord,
                        headword: fallbackWord,
                        sourceName: "AI fallback"
                    )
                }
                startEntryEnrichment(
                    entry: synthetic,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    sentence: sentence,
                    token: token,
                    completion: aiCompletion,
                    generation: lookupGeneration,
                    wordGeneration: lookupWordGeneration
                )
            }
            present(state: makeState(isLoading: false), focusInput: false)
        }
    }

    private func applyStructuredResult(
        _ result: DictionaryLookupResult,
        word: String,
        surfaceFallback: String?,
        sourceLanguage: DictionarySourceLanguage,
        targetLanguage: DictionaryTargetLanguage,
        sentence: String,
        token: DictionaryPanelToken?,
        native: DictionaryNativeLookup?,
        generation lookupGeneration: Int,
        wordGeneration lookupWordGeneration: Int
    ) {
        guard generation == lookupGeneration,
              wordGeneration == lookupWordGeneration,
              !Task.isCancelled
        else {
            return
        }
        guard let entry = Self.preferredEntry(in: result) else {
            // A native entry is already a valid result even when the online
            // provider has no matching record. Keep the native definition
            // visible without claiming that the word has no entry at all.
            currentError = native == nil
                ? DictionaryAPIError.noEntries.localizedDescription
                : nil
            if let aiCompletion {
                let fallbackWord = surfaceFallback ?? word
                let synthetic = Self.syntheticEntry(
                    word: fallbackWord,
                    sourceLanguage: sourceLanguage,
                    native: native
                )
                if native == nil {
                    currentWord = Self.syntheticPanelWord(
                        originalText: token?.text ?? fallbackWord,
                        headword: fallbackWord,
                        sourceName: "AI fallback"
                    )
                }
                startEntryEnrichment(
                    entry: synthetic,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    sentence: sentence,
                    token: token,
                    completion: aiCompletion,
                    generation: lookupGeneration,
                    wordGeneration: lookupWordGeneration
                )
            }
            present(state: makeState(isLoading: false), focusInput: false)
            return
        }
        currentWord = Self.panelWord(
            originalText: token?.text ?? word,
            entry: entry,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            fallbackAttribution: result.attribution
        )
        currentError = nil
        present(state: makeState(isLoading: false), focusInput: false)
        if let aiCompletion {
            startEntryEnrichment(
                entry: entry,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sentence: sentence,
                token: token,
                completion: aiCompletion,
                generation: lookupGeneration,
                wordGeneration: lookupWordGeneration
            )
        }
    }

    private func startEntryEnrichment(
        entry: DictionaryEntry,
        sourceLanguage: DictionarySourceLanguage,
        targetLanguage: DictionaryTargetLanguage,
        sentence: String,
        token: DictionaryPanelToken?,
        completion: @escaping AICompletion,
        generation enrichmentGeneration: Int,
        wordGeneration enrichmentWordGeneration: Int
    ) {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        let coreSource = Self.coreLanguage(sourceLanguage)
        let coreTarget = DictionaryLanguage(targetLanguage.rawValue)
        let focusToken = token.map {
            DictionaryToken(
                text: $0.text,
                sourceRange: $0.utf16Range,
                language: coreSource
            )
        }
        let cacheKey = Self.enrichmentCacheKey(
            entry: entry,
            sentence: sentence,
            sourceLanguage: coreSource,
            targetLanguage: coreTarget,
            focusToken: focusToken
        )
        if let cached = cachedEnrichments[cacheKey],
           generation == enrichmentGeneration,
           wordGeneration == enrichmentWordGeneration
        {
            apply(response: cached, targetLanguage: targetLanguage)
            present(state: makeState(isLoading: false), focusInput: false)
            return
        }
        let request = DictionaryAIRequest.entryEnrichment(
            entry: entry,
            sentence: sentence,
            sourceLanguage: coreSource,
            targetLanguage: coreTarget,
            focusToken: focusToken
        )
        let requestTask: Task<DictionaryAIResponse, Error>
        let requestID: UUID
        if let existing = inFlightEnrichments[cacheKey],
           let existingID = inFlightEnrichmentIDs[cacheKey]
        {
            requestTask = existing
            requestID = existingID
        } else {
            requestTask = Task { @MainActor in
                try await completion(request)
            }
            requestID = UUID()
            inFlightEnrichments[cacheKey] = requestTask
            inFlightEnrichmentIDs[cacheKey] = requestID
            Task { @MainActor [weak self] in
                if let response = try? await requestTask.value {
                    self?.cacheEnrichment(response, for: cacheKey)
                }
                guard let self,
                      self.inFlightEnrichmentIDs[cacheKey] == requestID
                else { return }
                self.inFlightEnrichments.removeValue(forKey: cacheKey)
                self.inFlightEnrichmentIDs.removeValue(forKey: cacheKey)
            }
        }
        enrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == enrichmentGeneration,
                   self.wordGeneration == enrichmentWordGeneration
                {
                    self.enrichmentTask = nil
                }
            }
            do {
                let response = try await requestTask.value
                guard self.generation == enrichmentGeneration,
                      self.wordGeneration == enrichmentWordGeneration,
                      !Task.isCancelled
                else { return }
                self.cacheEnrichment(response, for: cacheKey)
                self.apply(response: response, targetLanguage: targetLanguage)
                self.present(state: self.makeState(isLoading: false), focusInput: false)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == enrichmentGeneration,
                      self.wordGeneration == enrichmentWordGeneration,
                      !Task.isCancelled
                else { return }
                self.currentError = error.localizedDescription
                self.present(state: self.makeState(isLoading: false), focusInput: false)
            }
        }
    }

    private func startSentenceContext(generation contextGeneration: Int) {
        guard let aiCompletion else {
            return
        }
        let targetKey = sentenceTranslationCacheKey()
        if let cached = sentenceTranslations[targetKey] {
            sentenceTranslation = cached
            contextError = nil
            present(state: makeState(isLoading: true), focusInput: false)
            return
        }

        // A token navigation changes only the focused-word request. Keep one
        // sentence-context request alive for the query and let its response
        // remap the active token by UTF-16 range when segmentation arrives.
        guard contextTask == nil else { return }
        let source = sourceLanguage
        let target = targetLanguage
        let sourceText = query
        let includeSegmentation = sentenceTokens.contains { token in
            ["zh", "ja"].contains(resolvedSourceLanguage(for: token).canonicalCode)
        }
        contextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await aiCompletion(
                    .sentenceContext(
                        sourceText: sourceText,
                        sourceLanguage: Self.coreLanguage(source),
                        targetLanguage: DictionaryLanguage(target.rawValue),
                        focusToken: nil,
                        includeSegmentation: includeSegmentation,
                        includeReadings: false
                    )
                )
                guard self.generation == contextGeneration, !Task.isCancelled else {
                    return
                }
                if let translation = response.translation?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !translation.isEmpty {
                    let displayed = ChineseScript(languageTag: target.rawValue)?.convertProse(translation) ?? translation
                    self.sentenceTranslations[targetKey] = displayed
                    self.sentenceTranslation = displayed
                    self.contextError = nil
                }
                if let tokens = self.validatedPanelTokens(
                    response.segmentedTokens,
                    source: sourceText
                ), !tokens.isEmpty {
                    // A coherent AI segmentation has better contextual
                    // boundaries than the bounded native refinement. Keep it
                    // as the query's authoritative segmentation and cancel
                    // any late native pass so it cannot split a compound.
                    self.aiSegmentationApplied = true
                    self.nativeRefinementTask?.cancel()
                    self.nativeRefinementTask = nil
                    let previousToken = self.activeToken
                    self.sentenceTokens = tokens
                    self.activeToken = self.remapCurrentSelection(
                        previousToken,
                        in: tokens
                    )

                    let selectionChanged = Self.selectionChanged(
                        from: previousToken,
                        to: self.activeToken
                    )
                    if selectionChanged {
                        self.cancelWordTasks()
                        self.wordGeneration &+= 1
                        self.currentWord = nil
                        self.currentAIAdditions.removeAll()
                        self.currentError = nil
                    }
                    self.prefetchTasks.forEach { $0.cancel() }
                    self.prefetchTasks.removeAll()
                    if selectionChanged {
                        self.startActiveLookup(generation: contextGeneration)
                    }
                }
                self.present(state: self.makeState(isLoading: self.currentWord == nil), focusInput: false)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == contextGeneration, !Task.isCancelled else {
                    return
                }
                // Native tokens and a completed word remain usable even when
                // optional AI context fails; surface a non-blocking retry.
                self.contextError = error.localizedDescription
                self.present(
                    state: self.makeState(isLoading: self.currentWord == nil),
                    focusInput: false
                )
            }
            if self.generation == contextGeneration {
                self.contextTask = nil
            }
        }
    }

    private func startParagraphTranslation(generation translationGeneration: Int) {
        guard presentationMode == .translate,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        resolveParagraphTargetLanguage()
        let key = paragraphTranslationCacheKey()
        if let cached = paragraphTranslations[key] {
            paragraphTranslation = cached
            contextError = nil
            present(state: makeState(isLoading: false), focusInput: false)
            return
        }
        guard let aiCompletion else {
            contextError = "Set up an AI provider in Settings to translate this text."
            present(state: makeState(isLoading: false), focusInput: false)
            return
        }
        let sourceText = query
        let source = sourceLanguage
        let target = targetLanguage
        contextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await aiCompletion(.sentenceContext(
                    sourceText: sourceText,
                    sourceLanguage: Self.coreLanguage(source),
                    targetLanguage: DictionaryLanguage(target.rawValue),
                    includeSegmentation: false,
                    includeReadings: false,
                    translationOnly: true
                ))
                guard self.generation == translationGeneration,
                      self.presentationMode == .translate,
                      !Task.isCancelled else { return }
                let normalized = DictionaryParagraphTranslation.normalized(response.translation ?? "")
                guard response.kind == .sentenceContext, !normalized.isEmpty else {
                    throw NSError(domain: "DictionaryTranslation", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The AI provider returned no translation. Try again."])
                }
                let displayed = ChineseScript(languageTag: target.rawValue)?.convertProse(normalized) ?? normalized
                self.paragraphTranslations[key] = displayed
                self.paragraphTranslation = displayed
                self.contextError = nil
                self.present(state: self.makeState(isLoading: false), focusInput: false)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == translationGeneration,
                      self.presentationMode == .translate,
                      !Task.isCancelled else { return }
                self.paragraphTranslation = nil
                self.contextError = error.localizedDescription
                self.present(state: self.makeState(isLoading: false), focusInput: false)
            }
            if self.generation == translationGeneration { self.contextTask = nil }
        }
    }

    private func startNativeRefinement(
        generation refinementGeneration: Int,
        initialTokens: [DictionaryNativeToken]
    ) {
        guard initialTokens.contains(where: {
            $0.isWord && $0.language?.canonicalCode == DictionarySourceLanguage.chinese.canonicalCode
        }) else {
            return
        }

        nativeRefinementTask?.cancel()
        let refinement = nativeRefinement ?? { tokens in
            DictionaryLanguageService.refineChineseCompounds(
                in: tokens,
                dictionaryProbeLimit: 128
            )
        }

        if nativeRefinement == nil {
            // The synchronous Dictionary Services pass must not run on the
            // main actor. Keep the detached task owned by the wrapper so
            // cancellation reaches the probe loop as well as the UI guard.
            let detached = Task.detached(priority: .utility) {
                await refinement(initialTokens)
            }
            nativeRefinementTask = Task { @MainActor [weak self] in
                let refined = await withTaskCancellationHandler(
                    operation: { await detached.value },
                    onCancel: { detached.cancel() }
                )
                guard let self,
                      self.generation == refinementGeneration,
                      !Task.isCancelled,
                      !self.aiSegmentationApplied
                else { return }
                self.applyNativeRefinement(
                    refined,
                    generation: refinementGeneration
                )
            }
        } else {
            nativeRefinementTask = Task { @MainActor [weak self] in
                let refined = await refinement(initialTokens)
                guard let self,
                      self.generation == refinementGeneration,
                      !Task.isCancelled,
                      !self.aiSegmentationApplied
                else { return }
                self.applyNativeRefinement(
                    refined,
                    generation: refinementGeneration
                )
            }
        }
    }

    private func applyNativeRefinement(
        _ refinedTokens: [DictionaryNativeToken],
        generation refinementGeneration: Int
    ) {
        guard generation == refinementGeneration,
              !aiSegmentationApplied,
              mode == .sentence,
              !refinedTokens.isEmpty
        else { return }

        let refinedPanelTokens = refinedTokens.map(DictionaryPanelToken.init(native:))
        guard refinedPanelTokens != sentenceTokens else { return }
        nativeRefinementApplied = true
        let previousToken = activeToken
        sentenceTokens = refinedPanelTokens
        activeToken = remapCurrentSelection(previousToken, in: refinedPanelTokens)

        let selectionChanged = Self.selectionChanged(
            from: previousToken,
            to: activeToken
        )
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        if selectionChanged {
            cancelWordTasks()
            wordGeneration &+= 1
            currentWord = nil
            currentAIAdditions.removeAll()
            currentError = nil
            startActiveLookup(generation: refinementGeneration)
        } else if lookupTask == nil {
            // The focused entry may already be cached or complete by the
            // time a late compound is refined. Seed the new adjacent terms
            // without restarting the active lookup.
            prefetchAdjacentEntries(generation: refinementGeneration)
        }
        present(state: makeState(isLoading: currentWord == nil), focusInput: false)
    }

    private func prefetchAdjacentEntries(generation prefetchGeneration: Int) {
        guard let activeIndex = sentenceTokens.firstIndex(where: {
            $0.utf16Range == activeToken?.utf16Range
        }) else {
            return
        }
        let navigable = sentenceTokens.indices.filter {
            sentenceTokens[$0].isWordToken
        }
        guard let position = navigable.firstIndex(of: activeIndex) else {
            return
        }
        let adjacent = [position - 1, position + 1].filter { navigable.indices.contains($0) }
        for position in adjacent {
            let token = sentenceTokens[navigable[position]]
            let source = resolvedSourceLanguage(for: token)
            let task = Task { @MainActor [weak self] in
                guard let self,
                      self.generation == prefetchGeneration,
                      !Task.isCancelled
                else { return }
                _ = try? await self.lookup(
                    word: token.headword ?? token.text,
                    sourceLanguage: source
                )
            }
            prefetchTasks.append(task)
        }
    }

    private func lookup(
        word: String,
        sourceLanguage: DictionarySourceLanguage
    ) async throws -> DictionaryLookupResult {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.lookupCacheKey(
            word: normalizedWord,
            sourceLanguage: sourceLanguage
        )
        if let cached = cachedLookups[key] {
            return cached
        }
        if let inFlight = inFlightLookups[key] {
            return try await inFlight.value
        }

        let language = Self.coreLanguage(sourceLanguage)
        let service = lookupService
        let task = Task<DictionaryLookupResult, Error> {
            try await service.lookup(language: language, word: normalizedWord)
        }
        let requestID = UUID()
        inFlightLookups[key] = task
        inFlightLookupIDs[key] = requestID
        defer {
            if inFlightLookupIDs[key] == requestID {
                inFlightLookups.removeValue(forKey: key)
                inFlightLookupIDs.removeValue(forKey: key)
            }
        }
        let result = try await task.value
        cacheLookup(result, for: key)
        return result
    }

    private func cacheLookup(_ result: DictionaryLookupResult, for key: String) {
        if cachedLookups.count >= 256,
           cachedLookups[key] == nil,
           let oldest = cachedLookups.keys.first
        {
            cachedLookups.removeValue(forKey: oldest)
        }
        cachedLookups[key] = result
    }

    private static func lookupCacheKey(
        word: String,
        sourceLanguage: DictionarySourceLanguage
    ) -> String {
        let normalizedWord = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return "\(sourceLanguage.canonicalCode)\u{0000}\(normalizedWord)"
    }

    private func finishWithoutWord(generation lookupGeneration: Int, message: String) {
        guard generation == lookupGeneration else { return }
        currentError = message
        present(state: makeState(isLoading: false), focusInput: false)
    }

    // MARK: Panel callbacks

    private func present(state: DictionaryPanelViewState, focusInput: Bool) {
        if panel.isVisible {
            panel.update(state: state)
            return
        }
        if !NSApp.isActive {
            panelActivationDeadline = Date().addingTimeInterval(1)
        }
        panel.show(
            state: state,
            onSubmit: { [weak self] query in
                self?.submit(query)
            },
            onSelectToken: { [weak self] token in
                self?.select(token)
            },
            onTargetChange: { [weak self] target in
                self?.changeTarget(to: target)
            },
            onSourceChange: { [weak self] source in
                self?.changeSource(to: source)
            },
            onSpeak: { [weak self] request in
                self?.speechService.speak(request)
            },
            onRetry: { [weak self] in
                self?.retry()
            },
            onToggleMode: { [weak self] draft in
                self?.switchPresentationMode(draft: draft)
            },
            onDismiss: { [weak self] in
                self?.cancel(dismissPanel: false)
            },
            onOpenPermissionSettings: { [weak self] in
                self?.onOpenPermissionSettings()
            },
            history: panelHistoryItems(),
            historyError: historyError,
            onHistorySelect: { [weak self] item in
                self?.restoreHistory(item)
            },
            onHistoryDelete: { [weak self] id in
                self?.deleteHistory(id: id)
            },
            onHistoryClear: { [weak self] in
                self?.clearHistory()
            }
        )
        _ = focusInput
    }

    private func submit(_ submittedQuery: String) {
        beginLookup(for: submittedQuery)
    }

    private func switchPresentationMode(draft: String) {
        presentationMode = presentationMode == .dictionary ? .translate : .dictionary
        stateStore.dictionaryPresentationMode = presentationMode
        beginLookup(for: draft)
    }

    /// Invalidates the current lookup when the panel's clear control is used.
    /// The panel keeps the input field local, so this callback is separate from
    /// submitting a non-empty query and can be exercised by offscreen checks.
    func clearLookup() {
        beginLookup(for: "", recordHistory: false)
    }

    /// Restores a saved lookup through the same generation/cancellation path
    /// as a new submission. Kept internal so the offscreen integration checks
    /// can exercise history selection without activating a native popover.
    func restoreHistory(_ item: DictionaryPanelHistoryItem) {
        let restoredQuery = item.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !restoredQuery.isEmpty else { return }

        sourceOverride = item.sourceLanguage
        targetLanguage = item.targetLanguage
        presentationMode = item.presentationMode
        stateStore.dictionaryPresentationMode = presentationMode
        stateStore.dictionaryTargetLanguage = targetLanguage.rawValue
        historyError = historyStore.storageError?.localizedDescription
        // History restores the complete query and preferences through the
        // normal lookup pipeline without selection capture or a second history row.
        beginLookup(for: item.query, recordHistory: false)
    }

    private func deleteHistory(id: UUID) {
        guard historyStore.remove(id: id) else { return }
        handleHistoryStorageErrorIfNeeded()
        refreshHistory()
    }

    private func clearHistory() {
        historyStore.clear()
        handleHistoryStorageErrorIfNeeded()
        refreshHistory()
    }

    private func recordHistory(for submittedQuery: String) {
        let detected = sourceOverride.isAutomatic && !sourceLanguage.isAutomatic
            ? sourceLanguage.rawValue
            : nil
        _ = historyStore.record(
            query: submittedQuery,
            sourceLanguage: sourceOverride.rawValue,
            detectedSourceLanguage: detected,
            targetLanguage: targetLanguage.rawValue,
            presentationMode: presentationMode
        )
        handleHistoryStorageErrorIfNeeded()
        refreshHistory()
    }

    private func panelHistoryItems() -> [DictionaryPanelHistoryItem] {
        historyStore.items.map { item in
            DictionaryPanelHistoryItem(
                id: item.id,
                query: item.query,
                sourceLanguage: item.sourceLanguage,
                detectedSourceLanguage: item.detectedSourceLanguage,
                targetLanguage: item.targetLanguage,
                presentationMode: item.presentationMode,
                lookedUpAt: item.lookedUpAt
            )
        }
    }

    private func refreshHistory() {
        panel.updateHistory(panelHistoryItems(), errorMessage: historyError)
    }

    private func handleHistoryStorageErrorIfNeeded() {
        guard let storageError = historyStore.storageError else {
            historyError = nil
            return
        }
        historyError = storageError.localizedDescription
    }

    private func select(_ token: DictionaryPanelToken) {
        guard mode == .sentence, token.isWordToken else { return }
        let source = query as NSString
        guard token.utf16Range.location != NSNotFound, token.utf16Range.location >= 0,
              token.utf16Range.length > 0, NSMaxRange(token.utf16Range) <= source.length,
              source.substring(with: token.utf16Range) == token.text,
              sentenceTokens.contains(where: { $0.isWordToken && NSIntersectionRange($0.utf16Range, token.utf16Range).length > 0 })
        else { return }
        cancelWordTasks()
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        wordGeneration &+= 1
        activeToken = token
        phraseSelectionRange = sentenceTokens.contains(where: { $0.utf16Range == token.utf16Range && $0.text == token.text })
            ? nil : token.utf16Range
        currentWord = nil
        currentAIAdditions.removeAll()
        currentError = nil
        present(state: makeState(isLoading: true), focusInput: false)
        let lookupGeneration = generation
        if mode == .sentence,
           sentenceTranslations[sentenceTranslationCacheKey()] == nil
        {
            startSentenceContext(generation: lookupGeneration)
        }
        startActiveLookup(generation: lookupGeneration)
    }

    private func changeTarget(to target: DictionaryTargetLanguage) {
        guard target != targetLanguage else { return }
        targetLanguage = target
        stateStore.dictionaryTargetLanguage = target.rawValue
        if presentationMode == .translate {
            beginLookup(for: panel.currentDraft)
            return
        }
        restartCurrentLookup()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordHistory(for: query)
        }
    }

    private func changeSource(to source: DictionarySourceLanguage) {
        guard source != sourceOverride else { return }
        sourceOverride = source
        if presentationMode == .translate {
            beginLookup(for: panel.currentDraft)
            return
        }
        restartCurrentLookup()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordHistory(for: query)
        }
    }

    private func resolveParagraphTargetLanguage() {
        let resolved = DictionaryTranslationLanguagePolicy.targetLanguage(
            sourceLanguage: sourceOverride.rawValue,
            detectedSourceLanguage: sourceLanguage.rawValue,
            preferredTargetLanguage: targetLanguage.rawValue
        )
        if let target = DictionaryTargetLanguage(rawValue: resolved), target != targetLanguage {
            targetLanguage = target
            stateStore.dictionaryTargetLanguage = target.rawValue
        }
    }

    private func retry() {
        if presentationMode == .translate {
            beginLookup(for: panel.currentDraft, recordHistory: false)
            return
        }
        restartCurrentLookup()
    }

    private func restartCurrentLookup() {
        guard !query.isEmpty else {
            showManual(notice: lastCaptureNotice ?? "Type a word or sentence to look up.", generation: generation)
            return
        }
        let currentQuery = query
        let previousActiveToken = activeToken
        cancelAllTasks()
        generation &+= 1
        wordGeneration &+= 1
        sourceLanguage = DictionaryLanguageService.detect(
            currentQuery,
            preferred: sourceOverride
        )
        // Re-run tokenization when a source override changes; this also keeps
        // exact CJK whole-input matching consistent with the new language.
        let tokens = DictionaryLanguageService.tokenize(currentQuery, language: sourceOverride)
        sentenceTokens = tokens.map(DictionaryPanelToken.init(native:))
        mode = Self.isWholeInputWord(
            currentQuery,
            sourceLanguage: sourceLanguage,
            wordTokens: tokens,
            probe: wholeInputWordProbe
        ) ? .word : .sentence
        activeToken = mode == .sentence
            ? remapCurrentSelection(previousActiveToken, in: sentenceTokens)
            : nil
        sentenceTranslation = nil
        currentWord = nil
        currentAIAdditions.removeAll()
        currentError = nil
        contextError = nil
        aiSegmentationApplied = false
        nativeRefinementApplied = false
        present(state: makeState(isLoading: true), focusInput: false)
        if mode == .sentence {
            startSentenceContext(generation: generation)
        }
        startActiveLookup(generation: generation)
        if mode == .sentence {
            startNativeRefinement(
                generation: generation,
                initialTokens: tokens
            )
        }
    }

    private func cancelWordTasks() {
        lookupTask?.cancel()
        enrichmentTask?.cancel()
        inFlightLookups.values.forEach { $0.cancel() }
        inFlightLookups.removeAll()
        inFlightLookupIDs.removeAll()
        lookupTask = nil
        enrichmentTask = nil
    }

    private func cancelAllTasks() {
        captureTask?.cancel()
        cancelWordTasks()
        contextTask?.cancel()
        nativeRefinementTask?.cancel()
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        inFlightLookups.values.forEach { $0.cancel() }
        inFlightLookups.removeAll()
        inFlightLookupIDs.removeAll()
        inFlightEnrichments.values.forEach { $0.cancel() }
        inFlightEnrichments.removeAll()
        inFlightEnrichmentIDs.removeAll()
        captureTask = nil
        contextTask = nil
        nativeRefinementTask = nil
    }

    private func resetContext() {
        phraseSelectionRange = nil
        query = ""
        sourceOverride = .automatic
        sourceLanguage = .automatic
        mode = .manual
        sentenceTokens.removeAll()
        activeToken = nil
        sentenceTranslation = nil
        paragraphTranslation = nil
        currentWord = nil
        currentAIAdditions.removeAll()
        currentError = nil
        contextError = nil
        aiSegmentationApplied = false
        nativeRefinementApplied = false
        lastCaptureNotice = nil
    }

    private func sentenceTranslationCacheKey() -> String {
        [
            sourceLanguage.canonicalCode,
            targetLanguage.rawValue,
            query,
        ].joined(separator: "\u{0000}")
    }

    private func paragraphTranslationCacheKey() -> String {
        [sourceOverride.rawValue, sourceLanguage.rawValue, targetLanguage.rawValue, query]
            .joined(separator: "\u{0000}")
    }

    private static func enrichmentCacheKey(
        entry: DictionaryEntry,
        sentence: String,
        sourceLanguage: DictionaryLanguage,
        targetLanguage: DictionaryLanguage,
        focusToken: DictionaryToken?
    ) -> String {
        [
            sourceLanguage.rawValue,
            targetLanguage.rawValue,
            entry.headword,
            sentence,
            focusToken?.text ?? "",
            focusToken.map { "\($0.sourceRange.location):\($0.sourceRange.length)" } ?? "",
        ].joined(separator: "\u{0000}")
    }

    private func cacheEnrichment(_ response: DictionaryAIResponse, for key: String) {
        guard response.kind == .entryEnrichment else { return }
        if cachedEnrichments.count >= 128,
           let oldest = cachedEnrichments.keys.first
        {
            cachedEnrichments.removeValue(forKey: oldest)
        }
        cachedEnrichments[key] = response
    }

    // MARK: View state and mapping

    private func makeState(
        isLoading: Bool,
        notice: String? = nil
    ) -> DictionaryPanelViewState {
        let displayedError = currentError ?? contextError ?? notice
        let sentence: DictionaryPanelSentence?
        if mode == .sentence {
            let activeIndex = activeToken.flatMap { token in
                sentenceTokens.firstIndex(where: {
                    $0.isWordToken && NSIntersectionRange($0.utf16Range, token.utf16Range).length > 0
                })
            } ?? 0
            sentence = DictionaryPanelSentence(
                source: query,
                translation: sentenceTranslation,
                tokens: sentenceTokens,
                activeTokenIndex: activeIndex,
                activeRange: activeToken?.utf16Range,
                isSegmentationConfirmed: aiSegmentationApplied || nativeRefinementApplied
                    || !sentenceTokens.contains { token in
                        token.isWordToken
                            && ["zh", "ja"].contains(resolvedSourceLanguage(for: token).canonicalCode)
                    }
            )
        } else {
            sentence = nil
        }
        let attribution = currentWord.flatMap { word -> (String?, URL?)? in
            guard let sourceName = word.sourceName else { return nil }
            return (sourceName, word.sourceURL)
        }
        let displayedDetectedLanguage: DictionarySourceLanguage? = {
            guard sourceOverride.isAutomatic else { return nil }
            if let activeToken, !activeToken.isWhitespace, !activeToken.isPunctuation {
                let tokenLanguage = resolvedSourceLanguage(for: activeToken)
                if !tokenLanguage.isAutomatic {
                    return tokenLanguage
                }
            }
            return sourceLanguage.isAutomatic ? nil : sourceLanguage
        }()
        return DictionaryPanelViewState(
            query: query,
            sourceLanguage: sourceOverride,
            detectedSourceLanguage: displayedDetectedLanguage,
            targetLanguage: targetLanguage,
            mode: mode,
            presentationMode: presentationMode,
            paragraphTranslation: paragraphTranslation,
            isLoading: isLoading,
            errorMessage: displayedError,
            word: currentWord,
            sentence: sentence,
            aiAdditions: currentAIAdditions,
            attributionName: attribution?.0,
            attributionURL: attribution?.1
        )
    }

    private func apply(response: DictionaryAIResponse, targetLanguage: DictionaryTargetLanguage) {
        guard response.kind == .entryEnrichment else { return }
        let targetScript = ChineseScript(languageTag: targetLanguage.rawValue)
        let sourceScript = resolvedSourceLanguage(for: activeToken).rawValue
        let exampleScript = ChineseScript(languageTag: sourceScript)
        var additions = currentAIAdditions
        if let contextualMeaning = response.contextualMeaning?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !contextualMeaning.isEmpty {
            additions.append(targetScript?.convertProse(contextualMeaning) ?? contextualMeaning)
        }
        currentAIAdditions = additions
        guard let word = currentWord else { return }

        var meanings = word.meanings
        for definition in response.targetDefinitions {
            let value = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            meanings.append(DictionaryPanelMeaning(
                definition: targetScript?.convertProse(value) ?? value,
                isAIAddition: true
            ))
        }
        var examples = word.examples
        let exampleLanguage = resolvedSourceLanguage(for: activeToken)
        for example in response.exampleTranslations {
            let rawSource = example.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = exampleScript?.convertProse(rawSource) ?? rawSource
            let rawTranslation = example.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = targetScript?.convertProse(rawTranslation) ?? rawTranslation
            guard !source.isEmpty, !translation.isEmpty else { continue }
            if let index = examples.firstIndex(where: {
                Self.exampleKey($0.source, script: exampleScript) == Self.exampleKey(source, script: exampleScript)
            }) {
                let existing = examples[index]
                examples[index] = DictionaryPanelExample(
                    source: existing.source,
                    translation: translation,
                    language: existing.language,
                    isAIAddition: true
                )
            } else if examples.count < 2 {
                examples.append(DictionaryPanelExample(
                    source: source,
                    translation: translation,
                    language: exampleLanguage,
                    isAIAddition: true
                ))
            }
        }
        let dictionaryReading = Self.distinctReading(
            word.isAIReading ? nil : word.reading,
            from: word.phonetic
        )
        let aiReading = dictionaryReading == nil
            ? Self.distinctReading(response.readings.first ?? (word.isAIReading ? word.reading : nil), from: word.phonetic)
            : nil
        currentWord = DictionaryPanelWord(
            originalText: word.originalText,
            headword: word.headword,
            partOfSpeech: word.partOfSpeech,
            phonetic: word.phonetic,
            reading: dictionaryReading ?? aiReading,
            isAIReading: dictionaryReading == nil && aiReading != nil,
            meanings: meanings,
            examples: examples,
            sourceName: word.sourceName,
            sourceURL: word.sourceURL
        )
    }

    private func validatedPanelTokens(
        _ tokens: [DictionaryToken],
        source: String
    ) -> [DictionaryPanelToken]? {
        let sourceLength = (source as NSString).length
        let native = sentenceTokens.sorted { $0.utf16Range.location < $1.utf16Range.location }
        let nativeWords = native.filter(\.isWordToken)
        let sorted = tokens.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
        guard !sorted.isEmpty else { return nil }

        var previousEnd = 0
        var wordCandidates: [(token: DictionaryToken, range: NSRange, language: DictionarySourceLanguage)] = []
        wordCandidates.reserveCapacity(sorted.count)
        for token in sorted {
            let range = token.sourceRange
            guard range.location >= 0,
                  range.length > 0,
                  range.location <= sourceLength,
                  range.length <= sourceLength - range.location,
                  range.location >= previousEnd
            else {
                return nil
            }
            let actual = (source as NSString).substring(with: range)
            guard actual == token.text else {
                return nil
            }

            let hasWordContent = DictionaryLanguageService.isWordContent(token.text)
            let hasWhitespace = token.text.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            let hasPunctuation = token.text.unicodeScalars.contains {
                CharacterSet.punctuationCharacters.contains($0)
            }
            // Segmentation items are useful only for navigable words. A
            // mixed item such as "参考," or "文件 report" would cross a
            // native sentence boundary and make active-token remapping
            // ambiguous; keep the native punctuation/spacing gaps instead.
            if hasWordContent {
                guard !hasWhitespace else { return nil }
                let nativeMatch = nativeWords.first(where: {
                    $0.utf16Range == range && $0.text == token.text
                })
                // Apostrophes and hyphens can be part of a legitimate native
                // word (don't, l'amour, mother-in-law). Accept them only
                // when the AI range exactly matches that native word; a
                // punctuation-crossing compound is still rejected.
                if hasPunctuation {
                    guard nativeMatch != nil else { return nil }
                }
                guard !native.contains(where: { gap in
                    (gap.isWhitespace || gap.isPunctuation)
                        && Self.rangesOverlap(range, gap.utf16Range)
                }) else {
                    return nil
                }
                let language: DictionarySourceLanguage
                if sourceOverride.isAutomatic,
                   let tokenLanguage = token.language
                {
                    language = Self.sourceLanguage(for: tokenLanguage)
                } else if !sourceOverride.isAutomatic {
                    language = sourceOverride
                } else if let nativeMatch,
                          !nativeMatch.sourceLanguage.isAutomatic
                {
                    language = nativeMatch.sourceLanguage
                } else {
                    let detected = DictionaryLanguageService.detect(
                        token.text,
                        preferred: .automatic
                    )
                    language = detected.isAutomatic ? sourceLanguage : detected
                }
                wordCandidates.append((token, range, language))
            }
            previousEnd = range.location + range.length
        }

        guard !wordCandidates.isEmpty else { return nil }

        // Every native word span must remain represented. This rejects a
        // partial AI answer while still allowing punctuation, whitespace, and
        // other source gaps to stay native. A coherent AI compound may span
        // several native boundaries, but a weak character-by-character split
        // of a native CJK term is ignored so entries such as 参考 and idioms
        // such as 画蛇添足 remain selectable as complete words.
        for nativeWord in nativeWords {
            let nativeEnd = NSMaxRange(nativeWord.utf16Range)
            var coveredUntil = nativeWord.utf16Range.location
            for candidate in wordCandidates where candidate.range.location <= coveredUntil {
                let candidateEnd = NSMaxRange(candidate.range)
                guard candidateEnd > coveredUntil else { continue }
                if candidate.range.location > coveredUntil { break }
                coveredUntil = min(nativeEnd, candidateEnd)
                if coveredUntil >= nativeEnd { break }
            }
            guard coveredUntil >= nativeEnd else { return nil }

            let contained = wordCandidates.filter {
                $0.range.location >= nativeWord.utf16Range.location
                    && NSMaxRange($0.range) <= nativeEnd
            }
            if contained.count > 1,
               Self.isCJKText(nativeWord.text),
               contained.allSatisfy({ ( $0.token.text as NSString).length == 1 })
            {
                return nil
            }
        }

        // Merge the validated AI words with the original native gaps. This
        // preserves source/range fidelity for display and lets repeated words
        // remap by their exact UTF-16 range rather than by text alone.
        var mapped: [DictionaryPanelToken] = []
        mapped.reserveCapacity(native.count + wordCandidates.count)
        var cursor = 0

        func appendNativeGap(from start: Int, to end: Int) {
            guard start < end else { return }
            var gapCursor = start
            for token in native where token.utf16Range.location >= start
                && NSMaxRange(token.utf16Range) <= end
            {
                if token.utf16Range.location > gapCursor {
                    mapped.append(Self.rawPanelToken(
                        source: source,
                        range: NSRange(
                            location: gapCursor,
                            length: token.utf16Range.location - gapCursor
                        )
                    ))
                }
                mapped.append(token)
                gapCursor = NSMaxRange(token.utf16Range)
            }
            if gapCursor < end {
                mapped.append(Self.rawPanelToken(source: source, range: NSRange(
                    location: gapCursor,
                    length: end - gapCursor
                )))
            }
        }

        for candidate in wordCandidates {
            if candidate.range.location > cursor {
                appendNativeGap(from: cursor, to: candidate.range.location)
            }
            let nativeHeadword = native.first(where: {
                $0.utf16Range == candidate.range
                    && $0.text == candidate.token.text
                    && $0.sourceLanguage.canonicalCode
                        == candidate.language.canonicalCode
            })?.headword
            mapped.append(DictionaryPanelToken(
                text: candidate.token.text,
                utf16Range: candidate.range,
                // Preserve a native lemma when AI confirms the exact same
                // span and language. This keeps inflected English lookups
                // (for example, went -> go) stable after sentence AI
                // segmentation while still letting a genuinely new compound
                // use its surface form.
                headword: nativeHeadword ?? candidate.token.text,
                sourceLanguage: candidate.language,
                isPunctuation: false,
                isWhitespace: false
            ))
            cursor = max(cursor, NSMaxRange(candidate.range))
        }
        if cursor < sourceLength {
            appendNativeGap(from: cursor, to: sourceLength)
        }
        return mapped.sorted { $0.utf16Range.location < $1.utf16Range.location }
    }

    // MARK: Mapping helpers

    private static func preferredEntry(in result: DictionaryLookupResult) -> DictionaryEntry? {
        result.entries.first(where: { !$0.senses.isEmpty }) ?? result.entries.first
    }

    private static func rangesOverlap(_ left: NSRange, _ right: NSRange?) -> Bool {
        guard let right,
              left.location != NSNotFound,
              right.location != NSNotFound
        else {
            return false
        }
        return NSIntersectionRange(left, right).length > 0
    }

    private func remapCurrentSelection(_ previous: DictionaryPanelToken?, in tokens: [DictionaryPanelToken]) -> DictionaryPanelToken? {
        if let previous, phraseSelectionRange == previous.utf16Range { return previous }
        return Self.remapActiveToken(previous, in: tokens)
    }

    private static func remapActiveToken(
        _ previous: DictionaryPanelToken?,
        in tokens: [DictionaryPanelToken]
    ) -> DictionaryPanelToken? {
        let words = tokens.filter(\.isWordToken)
        guard let previous else {
            return words.first
        }
        return words.first(where: {
            $0.utf16Range == previous.utf16Range
        }) ?? words.first(where: {
            rangesOverlap($0.utf16Range, previous.utf16Range)
        }) ?? words.first(where: {
            $0.text == previous.text
        }) ?? words.first
    }

    private static func selectionChanged(
        from previous: DictionaryPanelToken?,
        to current: DictionaryPanelToken?
    ) -> Bool {
        switch (previous, current) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (previous?, current?):
            return previous.utf16Range != current.utf16Range
                || previous.headword != current.headword
                || previous.sourceLanguage != current.sourceLanguage
        }
    }

    private func resolvedSourceLanguage(
        for token: DictionaryPanelToken?
    ) -> DictionarySourceLanguage {
        if !sourceOverride.isAutomatic {
            return sourceOverride
        }
        guard let token,
              token.isWordToken,
              !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return sourceLanguage
        }
        if !token.sourceLanguage.isAutomatic {
            return token.sourceLanguage
        }
        let detected = DictionaryLanguageService.detect(
            token.text,
            preferred: .automatic
        )
        return detected.isAutomatic ? sourceLanguage : detected
    }

    private static func syntheticEntry(
        word: String,
        sourceLanguage: DictionarySourceLanguage,
        native: DictionaryNativeLookup?
    ) -> DictionaryEntry {
        let senses = native.map {
            [DictionarySense(definition: $0.definition)]
        } ?? []
        return DictionaryEntry(
            headword: word,
            language: coreLanguage(sourceLanguage),
            senses: senses
        )
    }

    private static func syntheticPanelWord(
        originalText: String,
        headword: String,
        sourceName: String
    ) -> DictionaryPanelWord {
        DictionaryPanelWord(
            originalText: originalText,
            headword: headword,
            sourceName: sourceName
        )
    }

    private static func panelWord(
        originalText: String,
        entry: DictionaryEntry,
        sourceLanguage: DictionarySourceLanguage,
        targetLanguage: DictionaryTargetLanguage,
        fallbackAttribution: DictionaryAttribution? = nil
    ) -> DictionaryPanelWord {
        let target = DictionaryLanguage(targetLanguage.rawValue)
        let sourceScript = ChineseScript(languageTag: sourceLanguage.rawValue)
        let targetScript = ChineseScript(languageTag: targetLanguage.rawValue)
        var meanings: [DictionaryPanelMeaning] = []
        var examples: [DictionaryPanelExample] = []
        func appendSense(_ sense: DictionarySense) {
            let translation = sense.translations.first(where: {
                $0.language?.endpointCode == target.endpointCode
            })?.text
            meanings.append(DictionaryPanelMeaning(
                definition: entry.language.endpointCode == "ja"
                    ? sense.definition
                    : (targetScript?.convertProse(sense.definition) ?? sense.definition),
                translation: translation.flatMap { targetScript?.convertProse($0) ?? $0 }
            ))
            for example in sense.examples {
                let displayed = sourceScript?.convertProse(example) ?? example
                guard !examples.contains(where: { exampleKey($0.source, script: sourceScript) == exampleKey(displayed, script: sourceScript) }) else { continue }
                if examples.count < 2 {
                    examples.append(DictionaryPanelExample(source: displayed, language: sourceLanguage))
                }
            }
            for sub in sense.subsenses { appendSense(sub) }
        }
        for sense in entry.senses { appendSense(sense) }
        return DictionaryPanelWord(
            originalText: originalText,
            headword: displayedHeadword(entry.headword, originalText: originalText, script: sourceScript),
            partOfSpeech: entry.partOfSpeech,
            phonetic: entry.pronunciation,
            reading: Self.distinctReading(entry.readings.first, from: entry.pronunciation),
            meanings: meanings,
            examples: examples,
            sourceName: attributionName(for: entry, fallback: fallbackAttribution),
            sourceURL: entry.attribution?.sourceURL
                ?? entry.attribution?.licenseURL
                ?? fallbackAttribution?.sourceURL
                ?? fallbackAttribution?.licenseURL
        )
    }

    private static func panelWord(
        originalText: String,
        native: DictionaryNativeLookup,
        sourceLanguage: DictionarySourceLanguage,
        targetLanguage: DictionaryTargetLanguage
    ) -> DictionaryPanelWord {
        DictionaryPanelWord(
            originalText: originalText,
            headword: ChineseScript(languageTag: sourceLanguage.rawValue)?.convert(native.query) ?? native.query,
            meanings: [DictionaryPanelMeaning(definition:
                sourceLanguage.canonicalCode == "zh"
                    ? (ChineseScript(languageTag: targetLanguage.rawValue)?.convertProse(native.definition) ?? native.definition)
                    : native.definition
            )],
            sourceName: native.sourceName,
            sourceURL: native.sourceURL
        )
    }

    private static func exampleKey(_ text: String, script: ChineseScript?) -> String {
        (script == nil ? text : ChineseScript.simplified.convert(text))
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func displayedHeadword(
        _ providerHeadword: String,
        originalText: String,
        script: ChineseScript?
    ) -> String {
        guard let script else { return providerHeadword }
        let displayed = script.convert(providerHeadword)
        // Some entries spell an equivalent variant in parentheses. Keep one
        // primary headword while retaining the provider entry and attribution.
        if let open = displayed.firstIndex(of: "("), displayed.hasSuffix(")") {
            let first = displayed[..<open].trimmingCharacters(in: .whitespaces)
            let alternate = displayed[displayed.index(after: open)..<displayed.index(before: displayed.endIndex)]
            if exampleKey(first, script: script) == exampleKey(String(alternate), script: script) { return first }
        }
        let selected = script.convert(originalText)
        return exampleKey(selected, script: script) == exampleKey(displayed, script: script) ? selected : displayed
    }

    private static func attributionName(
        for entry: DictionaryEntry,
        fallback: DictionaryAttribution? = nil
    ) -> String {
        let attribution = entry.attribution ?? fallback
        var parts: [String] = []
        if let sourceURL = attribution?.sourceURL,
           sourceURL.host?.localizedCaseInsensitiveContains("wiktionary") == true
        {
            parts.append("Wiktionary")
        }
        if let license = attribution?.licenseName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !license.isEmpty {
            parts.append(license)
        }
        parts.append("FreeDictionaryAPI.com")
        return parts.joined(separator: " · ")
    }

    private static func distinctReading(_ reading: String?, from phonetic: String?) -> String? {
        guard let reading,
              !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        guard let phonetic else {
            return reading
        }
        let normalize: (String) -> String = { value in
            value.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/[]"))
        }
        return normalize(reading) == normalize(phonetic)
            ? nil
            : reading
    }

    private static func sourceLanguage(for language: DictionaryLanguage) -> DictionarySourceLanguage {
        let source = DictionarySourceLanguage(rawValue: language.rawValue)
        return source.isAutomatic ? .automatic : source
    }

    private static func rawPanelToken(
        source: String,
        range: NSRange
    ) -> DictionaryPanelToken {
        let text = (source as NSString).substring(with: range)
        let whitespace = text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let punctuation = !whitespace && !DictionaryLanguageService.isWordContent(text)
        return DictionaryPanelToken(
            text: text,
            utf16Range: range,
            headword: whitespace || punctuation ? nil : text,
            sourceLanguage: .automatic,
            isPunctuation: punctuation,
            isWhitespace: whitespace
        )
    }

    private static func isCJKText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
        }
    }

    private static func coreLanguage(_ language: DictionarySourceLanguage) -> DictionaryLanguage {
        if language.rawValue.lowercased() == "zh-hant" { return .traditionalChinese }
        return switch language.canonicalCode {
        case DictionaryLanguage.spanish.rawValue: .spanish
        case DictionaryLanguage.chinese.rawValue: .chinese
        case DictionaryLanguage.japanese.rawValue: .japanese
        case DictionaryLanguage.english.rawValue: .english
        default: DictionaryLanguage(language.canonicalCode)
        }
    }

    private static func isWholeInputWord(
        _ query: String,
        sourceLanguage: DictionarySourceLanguage,
        wordTokens: [DictionaryNativeToken],
        probe: @MainActor (String, DictionarySourceLanguage) -> Bool
    ) -> Bool {
        let words = wordTokens.filter(\.isWord)
        guard !words.isEmpty else { return false }
        let compact = query.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }
        if ["zh", "ja"].contains(sourceLanguage.canonicalCode) {
            // NaturalLanguage can treat a compact CJK sentence as one token.
            // Ask Dictionary Services whether the complete input is an actual
            // dictionary term before choosing word mode.
            return compact && probe(query, sourceLanguage)
        }
        return words.count == 1 && words[0].text == query
    }

    private static func nativeWholeInputWordProbe(
        _ query: String,
        language: DictionarySourceLanguage
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let cfText = trimmed as CFString
        let length = CFStringGetLength(cfText)
        let termRange = DCSGetTermRangeInString(nil, cfText, 0)
        guard termRange.location == 0, termRange.length == length else {
            return false
        }
        return DictionaryNativeLookupService.lookupSynchronously(
            trimmed,
            sourceLanguage: language
        ) != nil
    }
}

private extension DictionaryPanelToken {
    var isWordToken: Bool {
        !isWhitespace && !isPunctuation
    }
}
