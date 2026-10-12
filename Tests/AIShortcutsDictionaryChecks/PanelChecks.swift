import AppKit
import Foundation

private struct DictionaryPanelCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func requirePanel(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw DictionaryPanelCheckFailure(description: message)
    }
}

@MainActor
private func panelDescendants(_ root: NSView) -> [NSView] {
    root.subviews.reduce(into: [root]) { result, child in
        result.append(contentsOf: panelDescendants(child))
    }
}

@MainActor
private func panelControl(_ root: NSView, identifier: String) -> NSView? {
    panelDescendants(root).first { $0.accessibilityIdentifier() == identifier }
}

@MainActor
private func sendPanelAction(_ control: NSControl, named identifier: String) throws {
    try requirePanel(control.isEnabled, "Disabled history control \(identifier)")
    guard let action = control.action else {
        throw DictionaryPanelCheckFailure(description: "History control \(identifier) has no action")
    }
    guard NSApp.sendAction(action, to: control.target, from: control) else {
        throw DictionaryPanelCheckFailure(description: "History action \(identifier) was not delivered")
    }
}

@MainActor
private func makeHistoryFixtureWindow(
    for controller: NSViewController,
    size: NSSize = NSSize(width: 344, height: 260)
) -> NSWindow {
    controller.loadViewIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func saveHistoryPreview(_ window: NSWindow, name: String = "history") throws {
    guard let index = CommandLine.arguments.firstIndex(of: "--previews"),
          CommandLine.arguments.indices.contains(index + 1),
          let view = window.contentView
    else { return }
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        .appendingPathComponent("history", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
        throw DictionaryPanelCheckFailure(description: "Cannot render history preview")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw DictionaryPanelCheckFailure(description: "Cannot encode history preview")
    }
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

@MainActor
private func dictionaryFixtureWindow() throws -> NSWindow {
    guard let window = NSApp.windows.first(where: {
        $0.isVisible && $0.accessibilityLabel() == "Dictionary"
    }) else {
        throw DictionaryPanelCheckFailure(description: "Dictionary fixture window is missing")
    }
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private struct PanelSentenceGeometry {
    let documentOrigin: NSPoint
    let windowTop: CGFloat
}

@MainActor
private func panelSentenceGeometry(_ content: NSView, source: String) -> PanelSentenceGeometry? {
    guard let sourceView = panelDescendants(content)
        .compactMap({ $0 as? NSTextView })
        .first(where: {
            $0.accessibilityLabel() == "Sentence source" && $0.string == source
        }),
        let scrollView = sourceView.enclosingScrollView,
        let document = scrollView.documentView,
        let window = content.window
    else { return nil }
    return PanelSentenceGeometry(
        documentOrigin: sourceView.convert(.zero, to: document),
        windowTop: window.frame.maxY
    )
}

@MainActor
private func samePanelSentenceGeometry(
    _ lhs: PanelSentenceGeometry,
    _ rhs: PanelSentenceGeometry,
    tolerance: CGFloat = 0.5
) -> Bool {
    abs(lhs.documentOrigin.x - rhs.documentOrigin.x) <= tolerance
        && abs(lhs.documentOrigin.y - rhs.documentOrigin.y) <= tolerance
        && abs(lhs.windowTop - rhs.windowTop) <= tolerance
}

@MainActor
func dictionaryPanelTranslationChecks() throws {
    let source = "A long captured first line that must remain readable in full.\nThe second line still matters after a mode change."
    var toggledDrafts: [String] = []
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    defer { panel.releaseResources() }
    panel.show(state: .init(query: source, sourceLanguage: .english,
                            targetLanguage: .japanese, presentationMode: .translate,
                            paragraphTranslation: "最初の行。次の行も大切です。"),
               onSubmit: { _ in }, onToggleMode: { toggledDrafts.append($0) })
    let window = try dictionaryFixtureWindow()
    guard let content = window.contentView,
          let field = panelControl(content, identifier: "dictionary.lookup") as? NSTextField,
          let sourceView = panelControl(content, identifier: "dictionary.translate.source") as? NSTextField,
          let resultView = panelControl(content, identifier: "dictionary.translate.result") as? NSTextField,
          let modeButton = panelControl(content, identifier: "dictionary.mode.toggle") as? NSButton
    else { throw DictionaryPanelCheckFailure(description: "Translate controls are missing") }
    try requirePanel(panel.currentDraft == source && sourceView.stringValue == source,
                     "Translate pane or search draft changed the full captured source")
    try requirePanel(!field.stringValue.contains("\n"),
                     "Multiline capture painted extra clipped lines in the one-line search field")
    try requirePanel(resultView.isSelectable && resultView.stringValue == "最初の行。次の行も大切です。",
                     "Translated paragraph is not selectable")
    try requirePanel(modeButton.accessibilityLabel() == "Switch to Dictionary",
                     "The mode control does not announce its outcome")
    try savePanelPreview(window, name: "translate-normal", subdirectory: "translation")

    func key(_ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                         modifierFlags: flags, timestamp: 1,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "\t", charactersIgnoringModifiers: "\t",
                                         isARepeat: repeatKey, keyCode: 48)
        else { throw DictionaryPanelCheckFailure(description: "Could not create Tab event") }
        return event
    }
    window.makeFirstResponder(field)
    window.sendEvent(try key())
    try requirePanel(toggledDrafts == [source], "Plain Tab did not switch exactly once with the full draft")
    window.sendEvent(try key(repeatKey: true))
    window.sendEvent(try key(.shift))
    window.sendEvent(try key(.option))
    try requirePanel(toggledDrafts == [source], "Held or modified Tab switched mode")
    if let editor = field.currentEditor() as? NSTextView {
        editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let compositionTab = try key()
        try requirePanel(panel.handlePanelKeyEvent(compositionTab) == false,
                         "Marked-text Tab was consumed instead of reaching the IME")
        try requirePanel(toggledDrafts == [source], "Tab switched mode during IME composition")
        editor.unmarkText()
    }
    let draftAfterComposition = panel.currentDraft
    window.sendEvent(try key(.capsLock))
    try requirePanel(toggledDrafts.count == 2 && toggledDrafts.last == draftAfterComposition,
                     "Plain Tab with Caps Lock did not switch mode")
    field.stringValue = "An unsubmitted edit."
    try sendPanelAction(modeButton, named: "dictionary.mode.toggle")
    try requirePanel(toggledDrafts.last == "An unsubmitted edit.",
                     "Clickable mode control submitted stale coordinator text")

    window.setContentSize(NSSize(width: 380, height: 320))
    panel.show(state: .init(query: source, sourceLanguage: .english,
                              targetLanguage: .japanese, presentationMode: .translate,
                              paragraphTranslation: "最初の行。次の行も大切です。"),
               onSubmit: { _ in }, onToggleMode: { toggledDrafts.append($0) })
    content.layoutSubtreeIfNeeded()
    let narrowSource = panelControl(content, identifier: "dictionary.translate.source")!
    let narrowResult = panelControl(content, identifier: "dictionary.translate.result")!
    try requirePanel(narrowResult.superview!.frame.minY > narrowSource.superview!.frame.minY,
                     "Narrow Translate panes did not stack")
    try savePanelPreview(window, name: "translate-narrow", subdirectory: "translation")
    let flattenedSource = source.replacingOccurrences(of: "\n", with: " ")
    field.stringValue = flattenedSource
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    try requirePanel(panel.currentDraft == flattenedSource,
                     "An explicit edit matching the display incorrectly restored hidden paragraph breaks")
    panel.update(state: .init(query: source, sourceLanguage: .english,
                              mode: .sentence,
                              sentence: .init(source: source, translation: "The full sentence.",
                                              tokens: DictionaryLanguageService.tokenize(source, language: .english)
                                                .map(DictionaryPanelToken.init(native:)))))
    try requirePanel(panelControl(content, identifier: "dictionary.translate.result") == nil,
                     "Returning to Dictionary left Translate output in the body")
    try savePanelPreview(window, name: "dictionary-return", subdirectory: "translation")
    let manyMeanings = (0..<18).map { DictionaryPanelMeaning(
        definition: "A long dictionary sense \($0) keeps the body scrollable before changing mode."
    ) }
    panel.update(state: .init(query: source, mode: .word,
                              word: .init(originalText: "source", headword: "source",
                                          meanings: manyMeanings)))
    guard let bodyScroll = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first else {
        throw DictionaryPanelCheckFailure(description: "Dictionary scroll view is missing")
    }
    bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    try requirePanel(bodyScroll.contentView.bounds.origin.y > 0,
                     "The Dictionary scroll fixture could not move")
    panel.update(state: .init(query: source, presentationMode: .translate,
                              paragraphTranslation: "The full paragraph."))
    try requirePanel(bodyScroll.contentView.bounds.origin.y == 0,
                     "Switching modes inherited a stale Dictionary scroll offset")
    window.setContentSize(NSSize(width: 620, height: 320))
    let longSource = Array(repeating: "A complete translation keeps every important detail in this paragraph.", count: 6).joined(separator: " ")
    panel.update(state: .init(query: longSource, presentationMode: .translate, isLoading: true))
    let loadingHeight = window.frame.height
    panel.update(state: .init(query: longSource, presentationMode: .translate,
                              paragraphTranslation: longSource))
    try requirePanel(window.frame.height > loadingHeight,
                     "A completed long translation did not grow from the initial loading viewport")
    if let result = panelControl(content, identifier: "dictionary.translate.result"),
       let pane = result.superview {
        try requirePanel(pane.frame.maxY <= bodyScroll.contentView.bounds.height + 0.5,
                         "The completed translation was hidden below the default viewport: pane \(pane.frame.maxY), viewport \(bodyScroll.contentView.bounds.height), panel \(window.frame.height)")
    }
    field.stringValue = ""
    _ = panel.control(field, textView: NSTextView(),
                      doCommandBy: #selector(NSResponder.insertNewline(_:)))
    try requirePanel(panelControl(content, identifier: "dictionary.translate.result") != nil
                     && modeButton.accessibilityLabel() == "Switch to Dictionary",
                     "Submitting an empty Translate draft reverted the panel to Dictionary")
    panel.update(state: .init(query: "", presentationMode: .dictionary))
    window.makeFirstResponder(modeButton)
    panel.update(state: .init(query: "", presentationMode: .translate))
    try requirePanel(window.firstResponder === field || window.firstResponder === field.currentEditor(),
                     "Switching an empty panel to Translate did not focus its input")
    print("PASS Translate pane layout, full draft, selectable output, Tab boundaries, and return")
}

@MainActor
private func savePanelPreview(
    _ window: NSWindow,
    name: String,
    subdirectory: String = "errors"
) throws {
    guard let index = CommandLine.arguments.firstIndex(of: "--previews"),
          CommandLine.arguments.indices.contains(index + 1),
          let view = window.contentView
    else { return }
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        .appendingPathComponent(subdirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
          let png = ({ () -> Data? in
              view.cacheDisplay(in: view.bounds, to: bitmap)
              return bitmap.representation(using: .png, properties: [:])
          })()
    else {
        throw DictionaryPanelCheckFailure(description: "Cannot render \(subdirectory) preview \(name)")
    }
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

/// Checks the compact-to-result resize path and the native field-cell geometry
/// that keeps the title, header controls, and lookup glyphs visually centered.
@MainActor
func dictionaryPanelLayoutChecks() throws {
    try dictionaryDefaultVisibilityChecks()
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    panel.show(state: .empty, onSubmit: { _ in })
    let window = try dictionaryFixtureWindow()
    defer { panel.releaseResources() }
    guard let content = window.contentView,
          let title = panelControl(content, identifier: "dictionary.header"),
          let source = panelControl(content, identifier: "dictionary.source"),
          let history = panelControl(content, identifier: "dictionary.history"),
          let close = panelDescendants(content).first(where: { $0.accessibilityLabel() == "Close Dictionary" }),
          let lookup = panelControl(content, identifier: "dictionary.lookup") as? NSTextField,
          let surface = panelControl(content, identifier: "dictionary.lookup.surface")
    else {
        throw DictionaryPanelCheckFailure(description: "Dictionary layout controls are missing")
    }

    try requirePanel(panelControl(content, identifier: "dictionary.target") is NSPopUpButton,
                     "Matching target language menu is missing")
    let headerMidY = title.frame.midY
    let titleGlyphRect = (title as? NSTextField)?.cell?.drawingRect(forBounds: title.bounds) ?? .zero
    try requirePanel(abs(titleGlyphRect.midY - title.bounds.midY) < 0.5, "Header title glyphs are not centered")
    for control in [source, history, close] {
        try requirePanel(abs(control.frame.midY - headerMidY) < 0.5, "Header controls are not vertically aligned")
    }
    try requirePanel(abs(lookup.frame.midY - surface.bounds.midY) < 0.5, "Lookup field frame is not centered")
    let drawnTextRect = lookup.cell?.drawingRect(forBounds: lookup.bounds) ?? .zero
    try requirePanel(abs(drawnTextRect.midY - lookup.bounds.midY) < 0.5, "Lookup glyph rect is not centered")
    try requirePanel(
        panelControl(content, identifier: "dictionary.status.keyboardHint") != nil,
        "Manual state is missing the Return and Escape hint"
    )

    let completeCapture = "First captured line.\nSecond captured line with meaning."
    panel.update(state: DictionaryPanelViewState(query: completeCapture, mode: .sentence))
    try requirePanel(panel.currentDraft == completeCapture,
                     "The search draft discarded a captured paragraph break")

    let word = DictionaryPanelWord(
        originalText: "hello",
        headword: "hello",
        partOfSpeech: "interjection",
        meanings: [.init(definition: "used as a greeting")]
    )
    panel.update(state: DictionaryPanelViewState(
        query: "hello",
        sourceLanguage: .english,
        mode: .word,
        word: word
    ))
    content.layoutSubtreeIfNeeded()
    let resizedTitle = panelControl(content, identifier: "dictionary.header")!
    let resizedSource = panelControl(content, identifier: "dictionary.source")!
    let resizedHistory = panelControl(content, identifier: "dictionary.history")!
    let resizedClose = panelDescendants(content).first(where: { $0.accessibilityLabel() == "Close Dictionary" })!
    for control in [resizedSource, resizedHistory, resizedClose] {
        try requirePanel(abs(control.frame.midY - resizedTitle.frame.midY) < 0.5, "Header alignment changed after resize")
    }
    try requirePanel(abs(resizedTitle.frame.midY - headerMidY) < 0.5, "Header title shifted after resize")

    let meaningLabel = panelDescendants(content)
        .compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Meaning: used as a greeting" }
    try requirePanel(meaningLabel != nil, "A single sense should not receive a generic 1 label")

    let sentenceSource = "Read this sentence.\nThen read it again."
    let sentenceTokens = [
        DictionaryPanelToken(text: "Read", utf16Range: NSRange(location: 0, length: 4)),
        DictionaryPanelToken(text: "this", utf16Range: NSRange(location: 5, length: 4)),
        DictionaryPanelToken(text: "sentence", utf16Range: NSRange(location: 10, length: 8)),
        DictionaryPanelToken(text: "Then", utf16Range: NSRange(location: 20, length: 4)),
        DictionaryPanelToken(text: "read", utf16Range: NSRange(location: 25, length: 4)),
        DictionaryPanelToken(text: "it", utf16Range: NSRange(location: 30, length: 2)),
        DictionaryPanelToken(text: "again", utf16Range: NSRange(location: 33, length: 5)),
    ]
    let sentence = DictionaryPanelSentence(
        source: sentenceSource,
        translation: "Read this sentence.\nThen read it again.",
        tokens: sentenceTokens,
        activeTokenIndex: 0
    )
    let loadingState = DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        isLoading: true,
        sentence: sentence
    )
    panel.update(state: loadingState)
    content.layoutSubtreeIfNeeded()
    guard let scrollView = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first,
          let loadingGeometry = panelSentenceGeometry(content, source: sentenceSource)
    else {
        throw DictionaryPanelCheckFailure(description: "Initial loading sentence did not render")
    }
    let loadingHeight = window.frame.height
    let loadingTop = window.frame.maxY
    try requirePanel(
        abs(scrollView.contentView.bounds.origin.y) <= 0.5,
        "Initial loading state did not start at the top of the sentence"
    )

    let tallWord = DictionaryPanelWord(
        originalText: "Read",
        headword: "Read",
        partOfSpeech: "verb",
        meanings: [
            .init(definition: "To look at and understand written words."),
            .init(definition: "To inspect or study a text carefully."),
            .init(definition: "To interpret a message or signal."),
            .init(definition: "To understand a written passage after careful attention."),
            .init(definition: "To study a document for useful information and context."),
            .init(definition: "To recognize a message and respond to its meaning."),
            .init(definition: "To examine a text aloud or silently for comprehension."),
            .init(definition: "To discover a fact by consulting a trusted source."),
        ],
        examples: [
            .init(source: "Read this sentence aloud."),
            .init(source: "Read it again before answering."),
        ]
    )
    let readyState = DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        word: tallWord,
        sentence: sentence
    )
    panel.update(state: readyState)
    content.layoutSubtreeIfNeeded()
    guard let readyGeometry = panelSentenceGeometry(content, source: sentenceSource) else {
        throw DictionaryPanelCheckFailure(description: "Initial ready sentence did not render")
    }
    let readyHeight = window.frame.height
    try requirePanel(readyHeight > loadingHeight + 1, "Initial ready content did not settle panel height")
    try requirePanel(abs(window.frame.maxY - loadingTop) <= 0.5, "Initial ready resize moved the panel window top")
    try requirePanel(
        samePanelSentenceGeometry(loadingGeometry, readyGeometry),
        "Initial ready settling moved the sentence source"
    )

    // The settled result may fit the available screen completely. Shrink the
    // fixture once to create a real scrollable viewport; subsequent same-query
    // state updates must still keep this user-sized viewport stable.
    window.setContentSize(NSSize(
        width: window.frame.width,
        height: min(420, max(360, readyHeight - 1))
    ))
    panel.update(state: readyState)
    content.layoutSubtreeIfNeeded()

    let bottom = max(
        1,
        scrollView.documentView!.frame.height - scrollView.contentView.bounds.height - 1
    )
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let scrolledOrigin = scrollView.contentView.bounds.origin
    let scrolledHeight = window.frame.height
    let scrolledTop = window.frame.maxY
    guard let scrolledGeometry = panelSentenceGeometry(content, source: sentenceSource) else {
        throw DictionaryPanelCheckFailure(description: "Settled sentence source disappeared after scrolling")
    }
    let frameBeforeBringForward = window.frame
    let appWasActive = NSApp.isActive
    lookup.stringValue = "Keep this unfinished draft"
    panel.bringForward()
    try requirePanel(panel.isVisible && window.frame == frameBeforeBringForward,
                     "Bringing Dictionary forward moved or hid its window")
    try requirePanel(lookup.stringValue == "Keep this unfinished draft",
                     "Bringing Dictionary forward discarded the lookup draft")
    try requirePanel(scrollView.contentView.bounds.origin == scrolledOrigin,
                     "Bringing Dictionary forward reset the scroll position")
    try requirePanel(NSApp.isActive == appWasActive,
                     "Offscreen presentation activated the application")

    let navigationState = DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        word: tallWord,
        sentence: DictionaryPanelSentence(
            source: sentenceSource,
            translation: sentence.translation,
            tokens: sentenceTokens,
            activeTokenIndex: 1
        )
    )
    panel.update(state: navigationState)
    content.layoutSubtreeIfNeeded()
    guard let navigationGeometry = panelSentenceGeometry(content, source: sentenceSource) else {
        throw DictionaryPanelCheckFailure(description: "Sentence source disappeared during navigation")
    }
    try requirePanel(abs(window.frame.height - scrolledHeight) <= 0.5, "Navigation resized a settled panel")
    try requirePanel(abs(window.frame.maxY - scrolledTop) <= 0.5, "Navigation moved the settled panel window")
    try requirePanel(
        samePanelSentenceGeometry(scrolledGeometry, navigationGeometry),
        "Navigation moved the scrolled sentence source"
    )
    try requirePanel(
        abs(scrollView.contentView.bounds.origin.y - scrolledOrigin.y) <= 0.5,
        "Navigation reset the settled sentence scroll"
    )

    panel.update(state: DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        isLoading: true,
        word: tallWord,
        sentence: navigationState.sentence
    ))
    content.layoutSubtreeIfNeeded()
    guard let loadingUpdateGeometry = panelSentenceGeometry(content, source: sentenceSource) else {
        throw DictionaryPanelCheckFailure(description: "Sentence source disappeared during same-query loading")
    }
    try requirePanel(abs(window.frame.height - scrolledHeight) <= 0.5, "Same-query loading resized a settled panel")
    try requirePanel(
        samePanelSentenceGeometry(scrolledGeometry, loadingUpdateGeometry),
        "Same-query loading moved the scrolled sentence source"
    )
    try requirePanel(
        abs(scrollView.contentView.bounds.origin.y - scrolledOrigin.y) <= 0.5,
        "Same-query loading reset the settled sentence scroll"
    )

    let longError = "The dictionary service could not be reached because the network request timed out while loading this entry. Try again later."
    panel.update(state: DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        errorMessage: longError,
        word: tallWord,
        sentence: navigationState.sentence
    ))
    content.layoutSubtreeIfNeeded()
    guard let errorGeometry = panelSentenceGeometry(content, source: sentenceSource),
          let errorLabel = panelControl(content, identifier: "dictionary.status.error") as? NSTextField
    else {
        throw DictionaryPanelCheckFailure(description: "Long error state did not render")
    }
    try requirePanel(abs(window.frame.height - scrolledHeight) <= 0.5, "Same-query error resized a settled panel")
    try requirePanel(
        samePanelSentenceGeometry(scrolledGeometry, errorGeometry),
        "Same-query error moved the scrolled sentence source"
    )
    try requirePanel(
        abs(scrollView.contentView.bounds.origin.y - scrolledOrigin.y) <= 0.5,
        "Same-query error reset the settled sentence scroll"
    )
    try requirePanel(errorLabel.toolTip == longError, "Error tooltip lost the full message")
    try requirePanel(
        errorLabel.accessibilityLabel()?.contains(longError) == true,
        "Error accessibility label lost the full message"
    )
    try requirePanel(!errorLabel.stringValue.isEmpty, "Error status has no visible summary")
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    try savePanelPreview(window, name: "error-620")

    window.setContentSize(NSSize(width: 380, height: window.frame.height))
    panel.update(state: DictionaryPanelViewState(
        query: sentenceSource,
        sourceLanguage: .english,
        mode: .sentence,
        errorMessage: longError,
        word: tallWord,
        sentence: navigationState.sentence
    ))
    content.layoutSubtreeIfNeeded()
    try savePanelPreview(window, name: "error-380")
    try requirePanel(
        panelDescendants(content)
            .compactMap { $0 as? NSTextField }
            .contains { $0.accessibilityIdentifier() == "dictionary.status.error" },
        "Compact error status disappeared at 380 points"
    )

    let noEntry = "No dictionary entry was found for that word."
    panel.update(state: DictionaryPanelViewState(
        query: "zzzz",
        sourceLanguage: .english,
        mode: .word,
        errorMessage: noEntry
    ))
    content.layoutSubtreeIfNeeded()
    try requirePanel(
        panelControl(content, identifier: "dictionary.status.retry") == nil,
        "A known missing entry should not offer Retry"
    )
    let noEntryLabel = panelControl(content, identifier: "dictionary.status.error") as? NSTextField
    try requirePanel(
        noEntryLabel?.stringValue.contains("edit") == true,
        "A known missing entry should show correction guidance"
    )

    try dictionaryRedesignChecks(panel: panel, window: window)
    print("PASS dictionary compact/result header, sizing, errors, and lookup alignment")
}

/// Exercises the body against both native scroller styles at the panel's
/// normal and compact widths. The sentence, controls, examples, disclosures,
/// and status actions all share the same right edge, leaving room for the
/// overlay scroller without charging its width twice in legacy mode.
@MainActor
func dictionaryPanelScrollerGutterChecks() throws {
    let source = "A clear trailing gutter keeps sentence text and pronunciation controls readable beside the native scrollbar."
    let tokens = DictionaryLanguageService.tokenize(source, language: .english)
        .map(DictionaryPanelToken.init(native:))
    let sentence = DictionaryPanelSentence(
        source: source,
        translation: "A clear margin keeps text and pronunciation controls readable beside the native scrollbar.",
        tokens: tokens,
        activeTokenIndex: 0
    )
    let meanings = [
        "A narrow reserved strip beside a native vertical scroller keeps long dictionary definitions clear of its track.",
        "The stable margin remains useful when an overlay scroller appears during a scroll gesture.",
        "A legacy scroller already sits outside the document viewport, so it needs only a small text margin.",
        "The body keeps one shared line width for meanings, examples, language notes, and attribution links.",
        "A wrapped definition can grow vertically without pushing an audio button into the scrolling strip.",
        "The panel preserves its available reading width when the user expands more dictionary details.",
        "Source text and translations remain aligned at the left edge while their right edges stay readable.",
        "The visible sentence controls remain separated from the native scrollbar at compact panel widths.",
    ].map { DictionaryPanelMeaning(definition: $0) }
    let examples = [
        DictionaryPanelExample(
            source: "The editor checked the full sentence, then used the next-word arrow to compare each unfamiliar expression.",
            translation: "The editor reviewed the complete sentence and compared each unfamiliar expression."
        ),
        DictionaryPanelExample(
            source: "After the definition loaded, the reader played the example aloud and followed its translation line by line.",
            translation: "Once the definition loaded, the reader listened to the example and followed its translation."
        ),
        DictionaryPanelExample(
            source: "A longer example wraps naturally while the small speaker button keeps its place at the trailing edge.",
            translation: "A long example wraps while its speaker button remains easy to reach."
        ),
        DictionaryPanelExample(
            source: "The compact panel keeps the same reading gutter when the user opens the remaining examples.",
            translation: "The compact panel preserves its reading margin when more examples are opened."
        ),
    ]
    let word = DictionaryPanelWord(
        originalText: "scrollbar",
        headword: "scrollbar",
        partOfSpeech: "noun",
        phonetic: "/ˈskoʊlˌbɑːr/",
        reading: "scroll bar",
        meanings: meanings,
        examples: examples
    )
    let state = DictionaryPanelViewState(
        query: source,
        sourceLanguage: .english,
        mode: .sentence,
        word: word,
        sentence: sentence,
        attributionName: "Dictionary reference · Wiktionary · CC BY-SA 4.0",
        attributionURL: URL(string: "https://en.wiktionary.org/wiki/scrollbar")
    )
    let errorState = DictionaryPanelViewState(
        query: source,
        sourceLanguage: .english,
        mode: .sentence,
        errorMessage: "The dictionary service could not load this long entry. Try again when the connection is available.",
        word: word,
        sentence: sentence,
        attributionName: "Dictionary reference · Wiktionary · CC BY-SA 4.0",
        attributionURL: URL(string: "https://en.wiktionary.org/wiki/scrollbar")
    )
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    panel.show(state: state, onSubmit: { _ in })
    let window = try dictionaryFixtureWindow()
    defer {
        window.orderOut(nil)
        panel.releaseResources()
    }
    guard let content = window.contentView,
          let scrollView = panelDescendants(window.contentView!).compactMap({ $0 as? NSScrollView }).first,
          let body = scrollView.documentView
    else {
        throw DictionaryPanelCheckFailure(description: "Dictionary body scroll view is missing")
    }

    let overlayScrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    let interstitialGap: CGFloat = 6
    for (style, name) in [(NSScroller.Style.overlay, "overlay"), (.legacy, "legacy")] {
        scrollView.scrollerStyle = style
        scrollView.autohidesScrollers = style == .overlay
        for width: CGFloat in [620, 380] {
            window.setContentSize(NSSize(width: width, height: 360))
            panel.update(state: state)
            content.layoutSubtreeIfNeeded()
            body.layoutSubtreeIfNeeded()

            let viewportWidth = scrollView.contentView.bounds.width
            let nativeScrollerStrip = style == .overlay ? overlayScrollerWidth : 0
            let expectedBodyWidth = viewportWidth - nativeScrollerStrip - interstitialGap
            try requirePanel(
                scrollView.hasVerticalScroller && !scrollView.hasHorizontalScroller,
                "The \(name) \(Int(width))-point body must keep only its vertical scroller"
            )
            try requirePanel(
                abs(body.frame.width - viewportWidth) <= 0.5,
                "The \(name) \(Int(width))-point document must match the viewport without horizontal overflow"
            )
            guard let sourceView = panelDescendants(body)
                .compactMap({ $0 as? NSTextView })
                .first(where: { $0.accessibilityLabel() == "Sentence source" }),
                  let next = panelDescendants(body).compactMap({ $0 as? NSButton })
                    .first(where: { $0.accessibilityLabel() == "Next sentence token" }),
                  let wordSpeaker = panelDescendants(body).compactMap({ $0 as? NSButton })
                    .first(where: { $0.accessibilityLabel() == "Speak scrollbar" }),
                  let exampleSpeaker = panelDescendants(body).compactMap({ $0 as? NSButton })
                    .first(where: { $0.accessibilityLabel() == "Speak example 1" })
            else {
                throw DictionaryPanelCheckFailure(description: "Sentence, navigation, or example audio control is missing")
            }

            let sourceFrame = sourceView.convert(sourceView.bounds, to: body)
            try requirePanel(
                abs(sourceFrame.width - expectedBodyWidth) <= 0.5,
                "The \(name) \(Int(width))-point sentence renderer did not use the shared body width"
            )
            try requirePanel(
                abs(sourceFrame.minX) <= 0.5,
                "The \(name) \(Int(width))-point sentence left edge drifted from the search column"
            )

            let bodyControls = panelDescendants(body).filter { $0 is NSControl || $0 is NSTextView }
            for control in bodyControls {
                let frame = control.convert(control.bounds, to: body)
                try requirePanel(
                    frame.maxX <= expectedBodyWidth + 0.5,
                    "The \(name) \(Int(width))-point body control \(control.accessibilityLabel() ?? String(describing: type(of: control))) entered the scrollbar gutter"
                )
            }
            try requirePanel(
                next.frame.maxX <= expectedBodyWidth + 0.5
                    && wordSpeaker.frame.maxX <= expectedBodyWidth + 0.5
                    && exampleSpeaker.convert(exampleSpeaker.bounds, to: body).maxX <= expectedBodyWidth + 0.5,
                "Navigation or audio controls entered the \(name) \(Int(width))-point scrollbar gutter"
            )

            let documentWidth = body.frame.width
            let sourceWidth = sourceFrame.width
            let maximumY = max(1, body.frame.height - scrollView.contentView.bounds.height - 1)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try requirePanel(scrollView.contentView.bounds.origin.y > 0, "The \(name) body did not scroll at \(Int(width)) points")
            try requirePanel(
                abs(body.frame.width - documentWidth) <= 0.5
                    && abs(sourceView.frame.width - sourceWidth) <= 0.5,
                "Scrolling changed the \(name) \(Int(width))-point text width"
            )

            // Capture the top of the reading surface after asking AppKit to
            // flash its actual native scroller. All window frames remain
            // outside visible monitor bounds during this settlement.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.flashScrollers()
            window.displayIfNeeded()
            content.displayIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.08))
            try savePanelPreview(window, name: "\(name)-\(Int(width))", subdirectory: "scrollbar")

            if let disclosure = panelControl(content, identifier: "dictionary.entry.disclosure") as? NSButton {
                try sendPanelAction(disclosure, named: "Expand long dictionary text")
                content.layoutSubtreeIfNeeded()
                for control in panelDescendants(body).filter({ $0 is NSControl || $0 is NSTextView }) {
                    try requirePanel(
                        control.convert(control.bounds, to: body).maxX <= expectedBodyWidth + 0.5,
                        "Expanding dictionary text entered the \(name) \(Int(width))-point scrollbar gutter"
                    )
                }
            }
            if let disclosure = panelControl(content, identifier: "dictionary.examples.disclosure") as? NSButton {
                try sendPanelAction(disclosure, named: "Expand dictionary examples")
                content.layoutSubtreeIfNeeded()
                for control in panelDescendants(body).filter({ $0 is NSControl || $0 is NSTextView }) {
                    try requirePanel(
                        control.convert(control.bounds, to: body).maxX <= expectedBodyWidth + 0.5,
                        "Expanding examples entered the \(name) \(Int(width))-point scrollbar gutter"
                    )
                }
            }

            panel.update(state: errorState)
            content.layoutSubtreeIfNeeded()
            guard let retry = panelControl(content, identifier: "dictionary.status.retry") as? NSButton else {
                throw DictionaryPanelCheckFailure(description: "The \(name) \(Int(width))-point retry control is missing")
            }
            let retryFrame = retry.convert(retry.bounds, to: body)
            try requirePanel(
                retryFrame.maxX <= expectedBodyWidth + 0.5,
                "The \(name) \(Int(width))-point retry action entered the scrollbar gutter"
            )
        }
    }
    print("PASS native body gutter at 620/380 points with overlay and legacy scrollers")
}

/// Exercises the production placement calculation against virtual monitors
/// whose frames are entirely offscreen. This covers genuine movement,
/// automatic sizing, activation boundaries, expiry, and release without
/// ordering a panel on any visible display.
@MainActor
func dictionaryPanelMovedPlacementChecks() throws {
    let firstScreen = DictionaryPanelScreenGeometry(
        frame: NSRect(x: -12_000, y: -12_000, width: 1_800, height: 1_400),
        visibleFrame: NSRect(x: -11_980, y: -11_960, width: 1_760, height: 1_320)
    )
    let secondScreen = DictionaryPanelScreenGeometry(
        frame: NSRect(x: -9_500, y: -12_000, width: 1_600, height: 1_200),
        visibleFrame: NSRect(x: -9_480, y: -11_960, width: 1_560, height: 1_120)
    )
    var now: TimeInterval = 10
    var pointer = NSPoint(x: -11_000, y: -11_000)
    let screens = [firstScreen, secondScreen]
    let panel = DictionaryPanelController(
        presentationMode: .offscreenTest,
        placementClock: { now },
        screenGeometryProvider: { screens },
        pointerLocationProvider: { pointer },
        usesSyntheticPlacementGeometry: true
    )

    func resultState(_ query: String, meanings: Int = 10, additions: Int = 0) -> DictionaryPanelViewState {
        let definition = "A detailed dictionary meaning remains readable while the panel grows around the active result and its examples. "
        let word = DictionaryPanelWord(
            originalText: query,
            headword: query,
            partOfSpeech: "noun",
            phonetic: "/\(query)/",
            meanings: (0..<meanings).map {
                DictionaryPanelMeaning(definition: "Meaning \($0 + 1): " + String(repeating: definition, count: 2))
            }
        )
        let extra = "The asynchronous context explains how this term is used in a complete sentence and preserves the reader's current placement. "
        return DictionaryPanelViewState(
            query: query,
            sourceLanguage: .english,
            mode: .word,
            word: word,
            aiAdditions: (0..<additions).map { "Context: \($0 + 1). " + String(repeating: extra, count: 2) }
        )
    }

    func assertCentered(_ frame: NSRect, on screen: DictionaryPanelScreenGeometry, _ message: String) throws {
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        try requirePanel(
            abs(frame.midX - usable.midX) <= 0.5 && abs(frame.midY - usable.midY) <= 0.5,
            message
        )
    }

    func simulateDrag(_ window: NSWindow, to origin: NSPoint) {
        let notification = Notification(name: Notification.Name("DictionaryPanelHarnessDrag"), object: window)
        window.delegate?.windowWillMove?(notification)
        window.setFrameOrigin(origin)
        window.delegate?.windowDidMove?(notification)
        panel.finishPanelWindowDrag()
    }

    panel.show(state: .empty, onSubmit: { _ in })
    let window = try dictionaryFixtureWindow()
    defer {
        window.orderOut(nil)
        panel.releaseResources()
    }

    try assertCentered(window.frame, on: firstScreen, "Initial active presentation did not center on the pointer's screen")
    try requirePanel(window.frame.maxX < 0 && window.frame.maxY < 0, "Synthetic placement unexpectedly entered the desktop")

    // windowDidMove alone can follow setFrameOrigin. It must not make a
    // programmatic frame change look like a user drag.
    let programmaticOrigin = NSPoint(x: firstScreen.visibleFrame.minX + 260, y: firstScreen.visibleFrame.minY + 120)
    window.setFrameOrigin(programmaticOrigin)
    panel.windowDidMove(Notification(name: Notification.Name("DictionaryPanelProgrammaticMove"), object: window))
    panel.bringForward()
    try assertCentered(window.frame, on: firstScreen, "An unmarked programmatic move became a user-selected placement")

    pointer = NSPoint(x: -8_700, y: -11_000)
    now = 20
    let firstResult = resultState("growth")
    panel.update(state: firstResult)
    try assertCentered(window.frame, on: firstScreen, "Automatic result growth did not keep the untouched panel centered")

    now = 30
    let movedOrigin = NSPoint(x: firstScreen.visibleFrame.minX + 260, y: firstScreen.visibleFrame.minY + 180)
    simulateDrag(window, to: movedOrigin)
    let draggedTop = window.frame.maxY
    now = 40
    let nextResult = resultState("growth two", meanings: 12)
    panel.update(state: nextResult)
    try requirePanel(
        abs(window.frame.minX - movedOrigin.x) <= 0.5 && abs(window.frame.maxY - draggedTop) <= 0.5,
        "A new query or its automatic resize discarded the dragged top-left anchor"
    )
    try requirePanel(window.frame.height > 320, "The placement fixture did not exercise automatic panel growth")

    now = 50
    let asyncResult = resultState("growth two", meanings: 12, additions: 8)
    panel.update(state: asyncResult)
    try requirePanel(
        abs(window.frame.minX - movedOrigin.x) <= 0.5 && abs(window.frame.maxY - draggedTop) <= 0.5,
        "Same-query asynchronous growth changed the moved session's placement anchor"
    )

    panel.dismiss()
    now = 60
    panel.show(state: asyncResult, onSubmit: { _ in })
    try requirePanel(
        abs(window.frame.minX - movedOrigin.x) <= 0.5 && abs(window.frame.maxY - draggedTop) <= 0.5,
        "A dragged location was discarded by a brief close/reopen"
    )

    guard let lookup = panelControl(window.contentView!, identifier: "dictionary.lookup") as? NSTextField else {
        throw DictionaryPanelCheckFailure(description: "Dictionary lookup field is missing from placement fixture")
    }
    now = 600
    let focus = Notification(name: NSControl.textDidBeginEditingNotification, object: lookup)
    panel.controlTextDidBeginEditing(focus)
    panel.controlTextDidEndEditing(focus)
    now = 661
    panel.update(state: resultState("growth two", meanings: 12, additions: 9))
    try requirePanel(
        abs(window.frame.minX - movedOrigin.x) <= 0.5 && abs(window.frame.maxY - draggedTop) <= 0.5,
        "A passive same-query update expired or moved an idle visible session"
    )
    pointer = NSPoint(x: -8_700, y: -11_000)
    now = 662
    panel.bringForward()
    try assertCentered(window.frame, on: secondScreen, "The first activation after inactivity did not center on the current screen")

    now = 700
    let secondOrigin = NSPoint(x: secondScreen.visibleFrame.minX + 100, y: secondScreen.visibleFrame.minY + 16)
    simulateDrag(window, to: secondOrigin)
    now = 1_300
    lookup.stringValue = "draft typed after timeout"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lookup))
    now = 1_301
    panel.update(state: resultState("pending expiry", meanings: 8))
    try assertCentered(
        window.frame,
        on: secondScreen,
        "Passive text activity erased a pending timeout before the next lookup could recenter"
    )
    now = 1_302
    panel.update(state: resultState("pending expiry", meanings: 8, additions: 6))
    try assertCentered(
        window.frame,
        on: secondScreen,
        "Post-timeout asynchronous growth moved the newly centered session"
    )

    now = 1_400
    let refreshedOrigin = NSPoint(x: secondScreen.visibleFrame.minX + 180, y: secondScreen.visibleFrame.minY + 16)
    simulateDrag(window, to: refreshedOrigin)
    now = 1_999
    lookup.stringValue = "user edit refreshes activity"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: lookup))
    now = 2_598
    panel.bringForward()
    try requirePanel(
        abs(window.frame.minX - refreshedOrigin.x) <= 0.5,
        "Human editing did not refresh the moved placement session"
    )
    now = 3_198
    guard let target = panelControl(window.contentView!, identifier: "dictionary.target") as? NSPopUpButton,
          let currentTarget = target.selectedItem?.representedObject as? String,
          let alternateIndex = target.itemArray.firstIndex(where: {
              ($0.representedObject as? String).map { $0 != currentTarget } ?? false
          }),
          let targetAction = target.action
    else {
        throw DictionaryPanelCheckFailure(description: "Target-language control is missing from placement fixture")
    }
    target.selectItem(at: alternateIndex)
    try requirePanel(
        NSApp.sendAction(targetAction, to: target.target, from: target),
        "Explicit target-language action was not delivered"
    )
    try assertCentered(window.frame, on: secondScreen, "A translation operation did not expire the moved session at 600 seconds")

    now = 3_200
    simulateDrag(window, to: refreshedOrigin)
    panel.releaseResources()
    now = 3_201
    panel.show(state: .empty, onSubmit: { _ in })
    try assertCentered(window.frame, on: secondScreen, "Resource release did not clear the moved placement session")

    now = 3_210
    simulateDrag(window, to: NSPoint(x: -20_000, y: -20_000))
    now = 3_211
    panel.bringForward()
    let usable = secondScreen.visibleFrame.insetBy(dx: 16, dy: 16)
    try requirePanel(
        window.frame.minX >= usable.minX - 0.5
            && window.frame.minY >= usable.minY - 0.5
            && window.frame.maxX <= usable.maxX + 0.5
            && window.frame.maxY <= usable.maxY + 0.5,
        "A moved panel outside every monitor was not recovered onto its retained screen"
    )
    try requirePanel(window.frame.maxX < 0 && window.frame.maxY < 0, "Placement recovery unexpectedly entered the desktop")
    print("PASS native placement sessions, activity expiry, screen recovery, and offscreen centering")
}

/// Exercises contextual segmentation for a mixed-script sentence.  The
/// coordinator owns production segmentation; this fixture supplies its
/// panel-facing projection so the UI contract remains testable while the
/// Chinese segmenter evolves independently.
@MainActor
func dictionaryPanelCompoundChecks() throws {
    let source = "中文English文件名里有参考和画蛇添足。\nWe call 画蛇添足 an idiom."
    let sourceNSString = source as NSString

    func find(_ text: String, afterUTF16 start: Int = 0) -> NSRange? {
        guard start >= 0, start <= sourceNSString.length else { return nil }
        let range = sourceNSString.range(
            of: text,
            options: [],
            range: NSRange(location: start, length: sourceNSString.length - start)
        )
        return range.location == NSNotFound ? nil : range
    }

    guard let reference = find("参考"),
          let firstIdiom = find("画蛇添足"),
          let we = find("We", afterUTF16: NSMaxRange(firstIdiom)),
          let call = find("call", afterUTF16: NSMaxRange(we)),
          let secondIdiom = find("画蛇添足", afterUTF16: NSMaxRange(call)),
          let an = find("an", afterUTF16: NSMaxRange(secondIdiom)),
          let idiomNoun = find("idiom", afterUTF16: NSMaxRange(an))
    else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence fixture ranges are incomplete")
    }

    let nativeTokens = DictionaryLanguageService.tokenize(source)
    try requirePanel(
        nativeTokens.map(\.text).joined() == source,
        "Native compound tokenization changed the complete source"
    )
    try requirePanel(
        nativeTokens.filter(\.isWord).contains(where: { $0.text == "中文" })
            && nativeTokens.filter(\.isWord).contains(where: { $0.text == "English" })
            && nativeTokens.filter(\.isWord).contains(where: { $0.text == "文件名" }),
        "Mixed Chinese and English filename segmentation lost a lexical run"
    )
    try requirePanel(
        nativeTokens.filter({ $0.isWord && $0.text == "参考" }).count == 1
            && !nativeTokens.contains(where: { $0.isWord && ["参", "考"].contains($0.text) }),
        "Native smart segmentation must keep 参考 as one dictionary word"
    )
    try requirePanel(
        nativeTokens.first(where: { $0.isWord && $0.text == "参考" })?.utf16Range == reference,
        "Native 参考 token did not retain its exact UTF-16 range"
    )
    try requirePanel(
        nativeTokens.filter({ $0.isWord && $0.text == "画蛇添足" }).count == 2,
        "Native smart segmentation did not preserve both idiom occurrences"
    )

    // The panel projection must carry native per-token language metadata. A
    // compatibility fallback here would hide a regression in that mapping and
    // make the Chinese speech assertion exercise the wrong path.
    let tokens = nativeTokens.map(DictionaryPanelToken.init(native:))
    try requirePanel(
        zip(nativeTokens, tokens).allSatisfy { native, panel in
            panel.sourceLanguage == (native.language ?? .automatic)
        },
        "Panel token projection lost native per-token language metadata"
    )

    var previousEnd = 0
    for candidate in tokens {
        try requirePanel(
            candidate.utf16Range.location >= previousEnd,
            "Compound token ranges are not ordered"
        )
        try requirePanel(
            candidate.utf16Range.location >= 0
                && NSMaxRange(candidate.utf16Range) <= sourceNSString.length
                && sourceNSString.substring(with: candidate.utf16Range) == candidate.text,
            "Compound token does not preserve its UTF-16 source range: \(candidate.text)"
        )
        previousEnd = NSMaxRange(candidate.utf16Range)
    }
    try requirePanel(
        tokens.contains(where: { $0.text == "参考" && $0.sourceLanguage == .chinese })
            && !tokens.contains(where: { $0.text == "参" || $0.text == "考" }),
        "Panel projection did not preserve 参考 as one Chinese word"
    )
    try requirePanel(
        firstIdiom != secondIdiom
            && tokens.filter({ $0.text == "画蛇添足" }).count == 2,
        "Repeated idiom occurrences were not kept as distinct spans"
    )
    try requirePanel(
        tokens.contains(where: { $0.text == "idiom" && $0.utf16Range == idiomNoun }),
        "Mixed English token lost its source range"
    )

    let firstIdiomIndex = tokens.firstIndex { $0.utf16Range == firstIdiom }!
    let secondIdiomIndex = tokens.firstIndex { $0.utf16Range == secondIdiom }!
    let word = DictionaryPanelWord(
        originalText: "画蛇添足",
        headword: "画蛇添足",
        partOfSpeech: "成语",
        reading: "huà shé tiān zú",
        meanings: [
            .init(definition: "to ruin a good thing by adding something unnecessary")
        ],
        examples: [
            .init(
                source: "这项改动有些画蛇添足。",
                translation: "That change is unnecessary.",
                language: .chinese
            )
        ]
    )

    func state(
        activeTokenIndex: Int,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) -> DictionaryPanelViewState {
        DictionaryPanelViewState(
            query: source,
            sourceLanguage: .automatic,
            detectedSourceLanguage: .english,
            mode: .sentence,
            isLoading: isLoading,
            errorMessage: errorMessage,
            word: word,
            sentence: DictionaryPanelSentence(
                source: source,
                translation: "The Chinese/English filename includes a reference and the idiom ‘draw legs on a snake’.\nWe call ‘draw legs on a snake’ an idiom.",
                tokens: tokens,
                activeTokenIndex: activeTokenIndex
            )
        )
    }

    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    var selectedTokens: [DictionaryPanelToken] = []
    var speechRequests: [DictionarySpeechRequest] = []
    panel.show(
        state: .empty,
        onSubmit: { _ in },
        onSelectToken: { selectedTokens.append($0) },
        onSpeak: { speechRequests.append($0) }
    )
    let window = try dictionaryFixtureWindow()
    defer {
        window.orderOut(nil)
        panel.releaseResources()
    }
    guard let content = window.contentView else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence fixture has no content view")
    }

    // Speech can run while a delayed initial lookup or Retry has no entry.
    // The placeholder displays a lemma, but speech keeps the source token.
    let pendingSource = "reviewed 参考!"
    let pendingTokens = [
        DictionaryPanelToken(text: "reviewed", utf16Range: NSRange(location: 0, length: 8), headword: "review", sourceLanguage: .english),
        DictionaryPanelToken(text: " ", utf16Range: NSRange(location: 8, length: 1), isWhitespace: true),
        DictionaryPanelToken(text: "参考", utf16Range: NSRange(location: 9, length: 2), sourceLanguage: .chinese),
        DictionaryPanelToken(text: "!", utf16Range: NSRange(location: 11, length: 1), isPunctuation: true),
        DictionaryPanelToken(text: "", utf16Range: NSRange(location: 12, length: 0)),
    ]
    var pendingSpeaker: NSButton?
    for (index, title, expectedText, language) in [
        (0, "review", "reviewed", DictionarySourceLanguage.english),
        (2, "参考", "参考", DictionarySourceLanguage.chinese),
    ] {
        panel.update(state: .init(query: pendingSource, sourceLanguage: .automatic,
            detectedSourceLanguage: .english, mode: .sentence, isLoading: true,
            sentence: .init(source: pendingSource, tokens: pendingTokens, activeTokenIndex: index)))
        guard let speaker = panelDescendants(content).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityLabel() == "Speak \(title)" }), speaker.isEnabled else {
            throw DictionaryPanelCheckFailure(description: "Pending active-word speaker is missing")
        }
        let priorCount = speechRequests.count
        try sendPanelAction(speaker, named: "Pending Speak \(title)")
        try requirePanel(speechRequests.count == priorCount + 1
                         && speechRequests.last?.text == expectedText
                         && speechRequests.last?.language == language
                         && speechRequests.last?.kind == .word,
                         "Pending word speaker did not speak original text with per-token language")
        pendingSpeaker = speaker
    }
    for invalidIndex in [1, 3, 4] {
        panel.update(state: .init(query: pendingSource, mode: .sentence, isLoading: true,
            sentence: .init(source: pendingSource, tokens: pendingTokens, activeTokenIndex: invalidIndex)))
        let priorCount = speechRequests.count
        try sendPanelAction(pendingSpeaker!, named: "Pending invalid token speaker")
        try requirePanel(speechRequests.count == priorCount, "Pending speech accepted whitespace, punctuation, or empty text")
    }
    panel.update(state: .init(query: pendingSource, mode: .sentence, isLoading: true,
                             sentence: .init(source: pendingSource, tokens: [])))
    let priorCount = speechRequests.count
    try sendPanelAction(pendingSpeaker!, named: "Pending missing token speaker")
    try requirePanel(speechRequests.count == priorCount, "Pending speech accepted a missing active token")

    let initialState = state(activeTokenIndex: firstIdiomIndex)
    panel.update(state: initialState)
    content.layoutSubtreeIfNeeded()
    guard let sourceView = panelDescendants(content)
        .compactMap({ $0 as? NSTextView })
        .first(where: { $0.accessibilityLabel() == "Sentence source" && $0.string == source }),
          let scrollView = sourceView.enclosingScrollView,
          let initialGeometry = panelSentenceGeometry(content, source: source)
    else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence source did not render in full")
    }

    try requirePanel(sourceView.string == source, "Sentence source lost whitespace or its newline")
    try requirePanel(
        sourceView.textStorage?.length == sourceNSString.length,
        "Sentence source UTF-16 length changed during rendering"
    )
    let sourceFrameHeight = sourceView.frame.height
    let initialScrollOrigin = scrollView.contentView.bounds.origin
    let tokenAttribute = NSAttributedString.Key("AIShortcuts.DictionaryPanelTokenIndex")
    try requirePanel(
        sourceView.textStorage?.attribute(tokenAttribute, at: firstIdiom.location, effectiveRange: nil) != nil,
        "First idiom is not a clickable token span"
    )
    try requirePanel(
        sourceView.textStorage?.attribute(NSAttributedString.Key("AIShortcuts.DictionaryActiveToken"), at: firstIdiom.location, effectiveRange: nil) != nil,
        "First idiom does not carry the active purple highlight"
    )

    // Deliver a real mouse event to the second occurrence. This keeps the
    // clickable-span check tied to NSTextView's UTF-16 hit-testing path rather
    // than only inspecting its attributed ranges.
    guard let layoutManager = sourceView.layoutManager,
          let textContainer = sourceView.textContainer
    else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence text layout is unavailable")
    }
    let secondGlyphRange = layoutManager.glyphRange(
        forCharacterRange: secondIdiom,
        actualCharacterRange: nil
    )
    let secondGlyphRect = layoutManager.boundingRect(
        forGlyphRange: secondGlyphRange,
        in: textContainer
    )
    guard let clickEvent = NSEvent.mouseEvent(
              with: .leftMouseDown,
              location: sourceView.convert(
                  NSPoint(
                      x: secondGlyphRect.midX + sourceView.textContainerInset.width,
                      y: secondGlyphRect.midY + sourceView.textContainerInset.height
                  ),
                  to: nil
              ),
              modifierFlags: [],
              timestamp: 0,
              windowNumber: window.windowNumber,
              context: nil,
              eventNumber: 0,
              clickCount: 1,
              pressure: 1
          )
    else {
        throw DictionaryPanelCheckFailure(description: "Could not construct a compound token click event")
    }
    sourceView.mouseDown(with: clickEvent)
    try requirePanel(
        selectedTokens.last?.utf16Range == secondIdiom,
        "Clicking the repeated idiom did not preserve its UTF-16 span"
    )

    guard let speak = panelDescendants(content)
        .compactMap({ $0 as? NSButton })
        .first(where: { $0.accessibilityLabel() == "Speak 画蛇添足" })
    else {
        throw DictionaryPanelCheckFailure(description: "Chinese idiom speech control is missing")
    }
    try sendPanelAction(speak, named: "Speak 画蛇添足")
    try requirePanel(
        speechRequests.last?.text == "画蛇添足"
            && speechRequests.last?.language == .chinese
            && speechRequests.last?.kind == .word,
        "Active Chinese token did not produce Chinese word speech"
    )

    guard let next = panelDescendants(content)
        .compactMap({ $0 as? NSButton })
        .first(where: { $0.accessibilityLabel() == "Next sentence token" })
    else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence next control is missing")
    }
    try sendPanelAction(next, named: "Next sentence token")
    try requirePanel(
        selectedTokens.last?.utf16Range == we,
        "Next sentence navigation did not skip punctuation and whitespace"
    )

    let secondState = state(activeTokenIndex: secondIdiomIndex)
    panel.update(state: secondState)
    content.layoutSubtreeIfNeeded()
    guard let secondSourceView = panelDescendants(content)
        .compactMap({ $0 as? NSTextView })
        .first(where: { $0.accessibilityLabel() == "Sentence source" && $0.string == source }),
          let secondGeometry = panelSentenceGeometry(content, source: source)
    else {
        throw DictionaryPanelCheckFailure(description: "Second idiom update lost the complete source")
    }
    try requirePanel(
        secondSourceView.textStorage?.attribute(tokenAttribute, at: secondIdiom.location, effectiveRange: nil) != nil
            && secondSourceView.textStorage?.attribute(NSAttributedString.Key("AIShortcuts.DictionaryActiveToken"), at: secondIdiom.location, effectiveRange: nil) != nil,
        "Second repeated idiom did not become the active clickable span"
    )
    try requirePanel(
        samePanelSentenceGeometry(initialGeometry, secondGeometry),
        "Changing the active idiom moved the source sentence"
    )
    try requirePanel(
        abs(secondSourceView.frame.height - sourceFrameHeight) <= 0.5
            && scrollView.contentView.bounds.origin == initialScrollOrigin,
        "Changing the active idiom changed source line height or scroll position"
    )

    guard let previous = panelDescendants(content)
        .compactMap({ $0 as? NSButton })
        .first(where: { $0.accessibilityLabel() == "Previous sentence token" })
    else {
        throw DictionaryPanelCheckFailure(description: "Compound sentence previous control is missing")
    }
    try sendPanelAction(previous, named: "Previous sentence token")
    try requirePanel(
        selectedTokens.last?.utf16Range == call,
        "Previous sentence navigation did not land on the prior word"
    )

    for (label, status) in [
        ("loading", DictionaryPanelViewState(query: source, sourceLanguage: .automatic, detectedSourceLanguage: .english, mode: .sentence, isLoading: true, word: word, sentence: secondState.sentence)),
        ("error", DictionaryPanelViewState(query: source, sourceLanguage: .automatic, detectedSourceLanguage: .english, mode: .sentence, errorMessage: "Lookup failed. Try again.", word: word, sentence: secondState.sentence)),
    ] {
        panel.update(state: status)
        content.layoutSubtreeIfNeeded()
        guard let statusSource = panelDescendants(content)
            .compactMap({ $0 as? NSTextView })
            .first(where: { $0.accessibilityLabel() == "Sentence source" && $0.string == source }),
              let statusGeometry = panelSentenceGeometry(content, source: source)
        else {
            throw DictionaryPanelCheckFailure(description: "Compound \(label) state lost the source sentence")
        }
        try requirePanel(
            samePanelSentenceGeometry(secondGeometry, statusGeometry),
            "Compound \(label) state moved the source sentence"
        )
        try requirePanel(
            abs(statusSource.frame.height - sourceFrameHeight) <= 0.5
                && scrollView.contentView.bounds.origin == initialScrollOrigin,
            "Compound \(label) state changed source line height or scroll position"
        )
    }

    panel.update(state: secondState)
    content.layoutSubtreeIfNeeded()
    try requirePanel(
        panelDescendants(content)
            .compactMap({ $0 as? NSTextView })
            .contains(where: { $0.accessibilityLabel() == "Sentence source" && $0.string == source }),
        "Compound ready state did not restore its complete source"
    )
    try savePanelPreview(window, name: "compound", subdirectory: "compound")

    window.setContentSize(NSSize(width: 380, height: window.frame.height))
    panel.update(state: secondState)
    content.layoutSubtreeIfNeeded()
    guard let compactSource = panelDescendants(content)
        .compactMap({ $0 as? NSTextView })
        .first(where: { $0.accessibilityLabel() == "Sentence source" && $0.string == source })
    else {
        throw DictionaryPanelCheckFailure(description: "380-point compound fixture lost its source")
    }
    try requirePanel(compactSource.frame.width <= 348, "380-point sentence source overflows its content width")
    guard let definition = panelDescendants(content)
        .compactMap({ $0 as? NSTextField })
        .first(where: { $0.stringValue == word.meanings[0].definition }),
          let cell = definition.cell
    else {
        throw DictionaryPanelCheckFailure(description: "Narrow compound definition is missing")
    }
    let requiredHeight = cell.cellSize(forBounds: NSRect(
        x: 0, y: 0, width: definition.frame.width, height: 10_000
    )).height
    try requirePanel(definition.frame.height >= ceil(requiredHeight),
                     "Narrow definition clips its wrapped text: \(definition.frame.height) < \(requiredHeight)")
    try savePanelPreview(window, name: "compound-380", subdirectory: "compound")

    print("PASS dictionary compound sentence, UTF-16 ranges, idiom navigation, and Chinese speech")
}

/// Exercises the history surface in an offscreen native window. Keeping this
/// separate from `main.swift` lets the integration harness opt into the UI
/// fixture without ever presenting an NSPopover on the user's desktop.
@MainActor
func dictionaryPanelHistoryChecks() throws {
    let firstID = UUID()
    let secondID = UUID()
    let history = [
        DictionaryPanelHistoryItem(
            id: firstID,
            query: "aprender idiomas",
            sourceLanguage: .spanish,
            targetLanguage: .english,
            lookedUpAt: Date(timeIntervalSince1970: 1_700_000_200)
        ),
        DictionaryPanelHistoryItem(
            id: secondID,
            query: "食べる",
            sourceLanguage: .japanese,
            targetLanguage: .english,
            lookedUpAt: Date(timeIntervalSince1970: 1_700_000_100)
        ),
    ]

    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    var selectedQueries: [String] = []
    var deletedIDs: [UUID] = []
    var clearCount = 0
    panel.show(
        state: .empty,
        onSubmit: { _ in },
        history: history,
        onHistorySelect: { selectedQueries.append($0.query) },
        onHistoryDelete: { deletedIDs.append($0) },
        onHistoryClear: { clearCount += 1 }
    )

    let historyController = panel.makeHistoryViewControllerForOffscreenFixture()
    let window = makeHistoryFixtureWindow(for: historyController, size: NSSize(width: 344, height: 240))
    defer {
        window.orderOut(nil)
        panel.releaseResources()
    }
    guard let content = window.contentView else {
        throw DictionaryPanelCheckFailure(description: "History fixture has no content view")
    }

    let firstQueryID = "dictionary.history.item.\(firstID.uuidString)"
    let secondQueryID = "dictionary.history.item.\(secondID.uuidString)"
    guard let firstQuery = panelControl(content, identifier: firstQueryID) as? NSButton,
          let secondQuery = panelControl(content, identifier: secondQueryID) as? NSButton
    else {
        throw DictionaryPanelCheckFailure(description: "History rows did not render in stored order")
    }
    try requirePanel(firstQuery.title == "aprender idiomas", "Newest history query is not first")
    try requirePanel(
        firstQuery.superview!.frame.minY < secondQuery.superview!.frame.minY,
        "History rows are vertically reversed"
    )
    for query in [firstQuery, secondQuery] {
        guard let row = query.superview,
              let metadata = row.subviews.compactMap({ $0 as? NSTextField }).first
        else {
            throw DictionaryPanelCheckFailure(description: "History row metadata did not render")
        }
        try requirePanel(query.frame.minY < metadata.frame.minY, "History query must appear above metadata")
    }
    try saveHistoryPreview(window)

    try sendPanelAction(firstQuery, named: firstQueryID)
    try requirePanel(selectedQueries == ["aprender idiomas"], "Reopen history action did not select the query")

    guard let firstDelete = panelControl(
        content,
        identifier: "dictionary.history.delete.\(firstID.uuidString)"
    ) as? NSButton else {
        throw DictionaryPanelCheckFailure(description: "History delete action is missing")
    }
    try sendPanelAction(firstDelete, named: firstDelete.accessibilityIdentifier())
    try requirePanel(deletedIDs == [firstID], "Delete history action did not report the selected item")
    try requirePanel(panelControl(content, identifier: firstQueryID) == nil, "Deleted history row remains visible")

    guard let clear = panelControl(content, identifier: "dictionary.history.clear") as? NSButton,
          let cancel = panelControl(content, identifier: "dictionary.history.clear.cancel") as? NSButton
    else {
        throw DictionaryPanelCheckFailure(description: "History clear controls are missing")
    }
    try sendPanelAction(clear, named: "dictionary.history.clear")
    try requirePanel(clear.title == "Clear all?" && !cancel.isHidden, "Clear did not enter inline confirmation")
    try sendPanelAction(cancel, named: "dictionary.history.clear.cancel")
    try requirePanel(clear.title == "Clear" && cancel.isHidden && clearCount == 0, "Clear cancellation was not local")
    try sendPanelAction(clear, named: "dictionary.history.clear")
    try sendPanelAction(clear, named: "dictionary.history.clear")
    try requirePanel(clearCount == 1, "Confirmed clear did not report the clear action")

    panel.updateHistory([], errorMessage: "History storage is read-only")
    let errorController = panel.makeHistoryViewControllerForOffscreenFixture()
    let errorWindow = makeHistoryFixtureWindow(for: errorController, size: NSSize(width: 344, height: 190))
    defer { errorWindow.orderOut(nil) }
    guard let errorContent = errorWindow.contentView,
          let errorClear = panelControl(errorContent, identifier: "dictionary.history.clear") as? NSButton,
          let errorCancel = panelControl(errorContent, identifier: "dictionary.history.clear.cancel") as? NSButton,
          let errorStatus = panelControl(errorContent, identifier: "dictionary.history.status") as? NSTextField
    else {
        throw DictionaryPanelCheckFailure(description: "History storage error surface is incomplete")
    }
    try requirePanel(errorStatus.stringValue == "History storage is read-only", "History error is not visible in its own surface")
    try sendPanelAction(errorClear, named: "dictionary.history.clear")
    try requirePanel(errorClear.title == "Clear all?" && !errorCancel.isHidden, "Error state cannot be cleared inline")
    try sendPanelAction(errorCancel, named: "dictionary.history.clear.cancel")
    try sendPanelAction(errorClear, named: "dictionary.history.clear")
    try sendPanelAction(errorClear, named: "dictionary.history.clear")
    try requirePanel(clearCount == 2, "Confirmed clear did not handle the empty error state")

    try saveHistoryPreview(errorWindow, name: "history-error")
    let longID = UUID()
    let longQuery = "She reviewed the detailed proposal and all its supporting documents before presenting the recommendation at the meeting."
    panel.updateHistory([.init(id: longID, query: longQuery, sourceLanguage: .automatic,
                              detectedSourceLanguage: .english, targetLanguage: .english)])
    let longController = panel.makeHistoryViewControllerForOffscreenFixture()
    let longWindow = makeHistoryFixtureWindow(for: longController)
    defer { longWindow.orderOut(nil) }
    try saveHistoryPreview(longWindow, name: "history-long")
    longWindow.setContentSize(NSSize(width: 280, height: 150))
    longWindow.contentView?.layoutSubtreeIfNeeded()
    guard let longContent = longWindow.contentView,
          let longButton = panelControl(longContent, identifier: "dictionary.history.item.\(longID.uuidString)") as? NSButton,
          let metadata = longButton.superview?.subviews.compactMap({ $0 as? NSTextField }).first else {
        throw DictionaryPanelCheckFailure(description: "Long history query is missing")
    }
    try requirePanel(longButton.toolTip == longQuery && longButton.accessibilityLabel()?.contains(longQuery) == true,
                     "History loses its complete query tooltip or accessible name")
    try requirePanel(longButton.cell?.wraps == true && longButton.frame.height <= 38, "History query is not limited to two lines")
    try requirePanel(metadata.stringValue.hasPrefix("EN → EN") && !metadata.stringValue.contains("Auto"),
                     "History still duplicates automatic/detected language metadata")
    try requirePanel(longContent.bounds.contains(longButton.convert(longButton.bounds, to: longContent)),
                     "History query overflows at narrow width")
    try saveHistoryPreview(longWindow, name: "history-long-280")
    panel.updateHistory([])
    let emptyController = panel.makeHistoryViewControllerForOffscreenFixture()
    let emptyWindow = makeHistoryFixtureWindow(for: emptyController)
    defer { emptyWindow.orderOut(nil) }
    try saveHistoryPreview(emptyWindow, name: "history-empty")

    print("PASS dictionary history panel ordering, actions, and offscreen preview")
}

@MainActor
private func dictionaryRedesignChecks(panel: DictionaryPanelController, window: NSWindow) throws {
    guard let content = window.contentView else { return }
    let senses = [
        "To examine something carefully before reaching a conclusion.",
        "To assess the quality or performance of a person or a piece of work.",
        "To study material again in preparation for an examination.",
        "To write a critical assessment of a book, film, or exhibition.",
        "To reconsider a decision in light of new evidence.",
        "To look back on past events and describe their significance.",
        "To inspect a military formation formally.",
        "To conduct a judicial reconsideration of a judgment.",
        "To check a document for accuracy and completeness.",
    ]
    let word = DictionaryPanelWord(originalText: "reviewed", headword: "review", partOfSpeech: "verb",
        phonetic: "[rɪˈvjuː]", reading: " /rɪˈvjuː/ ",
        meanings: senses.map { .init(definition: $0) } + [.init(definition: "  " + senses[0] + " "), .init(definition: "   ")],
        examples: [.init(source: "We reviewed the proposal before the meeting.", translation: "We reviewed the proposal before the meeting."),
                   .init(source: "She reviewed her notes before the examination.")],
        sourceName: "Wiktionary · CC BY-SA 4.0")
    var sourceChanges: [DictionarySourceLanguage] = []
    var targetChanges: [DictionaryTargetLanguage] = []
    var submissions = 0
    let state = DictionaryPanelViewState(query: "reviewed", sourceLanguage: .automatic,
        detectedSourceLanguage: .english, mode: .word, word: word)
    window.setContentSize(NSSize(width: 620, height: 560))
    panel.show(state: state, onSubmit: { _ in submissions += 1 },
               onTargetChange: { targetChanges.append($0) }, onSourceChange: { sourceChanges.append($0) })
    func fields() -> [NSTextField] { panelDescendants(content).compactMap { $0 as? NSTextField } }
    func meaningCount() -> Int { fields().filter { $0.accessibilityLabel()?.hasPrefix("Meaning ") == true && $0.accessibilityLabel()?.contains(":") == true }.count }
    func disclosure() -> NSButton? { panelControl(content, identifier: "dictionary.meanings.disclosure") as? NSButton }
    guard let source = panelControl(content, identifier: "dictionary.source") as? NSPopUpButton,
          let target = panelControl(content, identifier: "dictionary.target") as? NSPopUpButton,
          let search = panelControl(content, identifier: "dictionary.lookup.surface"),
          let heading = fields().first(where: { $0.accessibilityLabel() == "Headword review" }),
          let reading = panelControl(content, identifier: "dictionary.pronunciation") as? NSTextField,
          let collapsed = disclosure() else { throw DictionaryPanelCheckFailure(description: "Redesigned controls are missing") }
    try requirePanel(type(of: source.cell!) == type(of: target.cell!) && source.frame.height == target.frame.height
                     && abs(source.frame.midY - target.frame.midY) < 0.5, "Language controls do not share their style and geometry")
    try requirePanel(abs(heading.convert(heading.bounds, to: content).minX - search.frame.minX) < 0.5,
                     "Headword and search surface do not share the horizontal gutter")
    try requirePanel(reading.stringValue == "IPA [rɪˈvjuː]" && fields().filter { $0.accessibilityIdentifier() == "dictionary.pronunciation" }.count == 1,
                     "Equivalent bracketed readings appear twice")
    try requirePanel(!fields().contains { $0.stringValue.hasPrefix("Original:") }, "Inflection still has a redundant Original row")
    try requirePanel(meaningCount() == 3 && collapsed.title == "Show 6 more meanings", "Senses did not collapse or normalize display duplicates")
    try requirePanel(fields().contains { $0.accessibilityLabel()?.hasPrefix("Example 1:") == true }, "Collapsed senses lost the examples")
    try savePanelPreview(window, name: "many-meanings-620", subdirectory: "redesign")
    try sendPanelAction(collapsed, named: "meanings disclosure")
    try requirePanel(meaningCount() == 9 && disclosure()?.title == "Show fewer meanings" && submissions == 0,
                     "Expanding meanings discarded data or submitted a lookup")
    panel.update(state: state)
    try requirePanel(meaningCount() == 9, "Same-query enrichment reset disclosure state")
    try savePanelPreview(window, name: "many-meanings-expanded-620", subdirectory: "redesign")
    if let expanded = disclosure() { try sendPanelAction(expanded, named: "collapse meanings") }
    window.setContentSize(NSSize(width: 380, height: 580))
    panel.update(state: state)
    content.layoutSubtreeIfNeeded()
    for menu in [source, target] {
        try requirePanel(content.bounds.contains(menu.convert(menu.bounds, to: content)), "Narrow language menu overflows")
    }
    for meaning in fields().filter({ $0.accessibilityLabel()?.hasPrefix("Meaning ") == true && $0.accessibilityLabel()?.contains(":") == true }) {
        let size = meaning.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: meaning.frame.width, height: 10_000))
        try requirePanel(meaning.frame.height >= ceil(size.height), "Narrow wrapped meaning is clipped")
    }
    try savePanelPreview(window, name: "many-meanings-380", subdirectory: "redesign")
    panel.update(state: .init(query: state.query, mode: .word, isLoading: true, word: word))
    try requirePanel(!fields().contains { $0.stringValue.contains("Looking up") }
                     && panelControl(content, identifier: "dictionary.status") == nil,
                     "Loading restored the recurring text/status gap")
    guard let loading = panelControl(content, identifier: "dictionary.status.loading"),
          let button = panelControl(content, identifier: "dictionary.lookup.submit") else {
        throw DictionaryPanelCheckFailure(description: "Quiet search progress missing")
    }
    try requirePanel(button.convert(button.bounds, to: content).contains(loading.convert(loading.bounds, to: content)),
                     "Loading progress sits outside the search button")
    try savePanelPreview(window, name: "loading-380", subdirectory: "redesign")
    let aiWord = DictionaryPanelWord(originalText: "画蛇添足", headword: "画蛇添足", partOfSpeech: "成语",
        phonetic: "/xwa ʂɤ tʰjɛn tsu/", reading: "huà shé tiān zú", isAIReading: true,
        meanings: [.init(definition: "To spoil something by adding unnecessary detail.")],
        examples: [.init(source: "这句话已经很清楚，再解释就是画蛇添足。", translation: "The sentence is already clear; further explanation would be unnecessary.", language: .chinese)])
    for width in [CGFloat(620), 380] {
        window.setContentSize(NSSize(width: width, height: 560))
        panel.update(state: .init(query: "画蛇添足", sourceLanguage: .chinese, mode: .word, word: aiWord,
                                 aiAdditions: ["An unnecessary addition makes the original worse."]))
        guard let row = panelControl(content, identifier: "dictionary.pronunciation") as? NSTextField else {
            throw DictionaryPanelCheckFailure(description: "AI reading metadata missing")
        }
        try requirePanel(row.stringValue == "huà shé tiān zú · AI  ·  IPA /xwa ʂɤ tʰjɛn tsu/", "AI reading order/provenance is inconsistent")
        try requirePanel(!fields().contains { $0.stringValue.hasPrefix("AI reading:") }, "AI reading appears in footer")
        try savePanelPreview(window, name: "ai-reading-\(Int(width))", subdirectory: "redesign")
    }
    let fullSource = "I reviewed the proposal.\nThen I reviewed it again."
    let fullTokens = DictionaryLanguageService.tokenize(fullSource, language: .english).map(DictionaryPanelToken.init(native:))
    let compactWord = DictionaryPanelWord(originalText: "reviewed", headword: "review", partOfSpeech: "verb",
        phonetic: "/rɪˈvjuː/", meanings: Array(word.meanings.prefix(2)), examples: word.examples)
    window.setContentSize(NSSize(width: 380, height: 740))
    panel.update(state: .init(query: fullSource, sourceLanguage: .english, targetLanguage: .spanish, mode: .sentence, word: compactWord,
        sentence: .init(source: fullSource, translation: "Revisé la propuesta.\nLuego la revisé de nuevo.", tokens: fullTokens,
                       activeTokenIndex: fullTokens.firstIndex(where: { $0.text == "reviewed" }) ?? 0)))
    try savePanelPreview(window, name: "sentence-380-full", subdirectory: "redesign")
    source.selectItem(withTitle: DictionarySourceLanguage.spanish.displayName)
    _ = NSApp.sendAction(source.action!, to: source.target, from: source)
    target.selectItem(withTitle: DictionaryTargetLanguage.chinese.displayName)
    _ = NSApp.sendAction(target.action!, to: target.target, from: target)
    try requirePanel(sourceChanges == [.spanish] && targetChanges == [.chinese], "Language menu callbacks are not connected")
    try requirePanel(source.numberOfItems > 50, "Source correction lost broad language choices")
    let sentence = "Review 中文."
    let tokens = [DictionaryPanelToken(text: "Review", utf16Range: NSRange(location: 0, length: 6), sourceLanguage: .english),
                  DictionaryPanelToken(text: "中文", utf16Range: NSRange(location: 7, length: 2), sourceLanguage: .chinese)]
    panel.update(state: .init(query: sentence, targetLanguage: .english, mode: .sentence, word: word,
        sentence: .init(source: sentence, translation: "Review Chinese.", tokens: tokens)))
    try requirePanel(fields().contains { $0.accessibilityLabel() == "Sentence translation: Review Chinese." }, "Mixed-script translation was hidden")
    panel.update(state: .init(query: sentence, sourceLanguage: .english, targetLanguage: .english, mode: .sentence, word: word,
        sentence: .init(source: sentence, translation: "Review Chinese.", tokens: tokens)))
    try requirePanel(fields().contains { $0.accessibilityLabel() == "Sentence translation: Review Chinese." }, "Manual source override hid a mixed-script translation")
    panel.update(state: .init(query: "Review the document.", sourceLanguage: .english, targetLanguage: .english,
        mode: .sentence, word: word, sentence: .init(source: "Review the document.", translation: "Examine the document.",
        tokens: [DictionaryPanelToken(text: "Review", utf16Range: NSRange(location: 0, length: 6), sourceLanguage: .english)])))
    try requirePanel(!fields().contains { $0.accessibilityLabel()?.hasPrefix("Sentence translation:") == true },
                     "Same-language sentence translation still adds redundant copy")
    window.setContentSize(NSSize(width: 380, height: 320))
    panel.update(state: .empty)
    content.layoutSubtreeIfNeeded()
    guard let compactScroll = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first else {
        throw DictionaryPanelCheckFailure(description: "Compact manual scroll region missing")
    }
    try requirePanel(content.bounds.contains(compactScroll.convert(compactScroll.bounds, to: content)),
                     "Compact narrow manual body extends outside the panel")
    try savePanelPreview(window, name: "manual-380", subdirectory: "redesign")
    print("PASS matching language menus, shared gutter, quiet progress, sense disclosure, AI pronunciation, and translations")
}


/// Exercise real result transitions without giving the fixture an oversized viewport.
@MainActor
private func dictionaryDefaultVisibilityChecks() throws {
    let panel = DictionaryPanelController(presentationMode: .offscreenTest)
    panel.show(state: .empty, onSubmit: { _ in })
    let window = try dictionaryFixtureWindow()
    defer { panel.releaseResources() }
    guard let content = window.contentView else { return }
    let permission = DictionaryPanelWord(originalText: "permission", headword: "permission", partOfSpeech: "noun",
        phonetic: "/pəˈmɪʃən/", reading: "puh-MISH-un", isAIReading: true,
        meanings: [.init(definition: "Consent or authorization to do something.", translation: "允许或授权做某事。"),
                   .init(definition: "The act of allowing someone to do something.", translation: "准许某人做某事。"),
                   .init(definition: "An official document granting authorization.", translation: "授予许可的正式文件。"),
                   .init(definition: "Access rights granted to a user or program.")],
        examples: [.init(source: "You need permission before entering the laboratory.", translation: "进入实验室之前需要获得许可。"),
                   .init(source: "She gave us permission to use her photographs.", translation: "她允许我们使用她的照片。"),
                   .init(source: "The program requests permission to open the file.")],
        sourceName: "Wiktionary · CC BY-SA 4.0")
    let context = "Context: Here permission means approval or authorization to perform an action. "
        + String(repeating: "It describes consent granted by the person responsible. ", count: 12)
    let sentence = "We need permission to record the meeting.\nPlease ask for permission before you begin."
    let native = DictionaryLanguageService.tokenize(sentence, language: .english)
    let tokens = native.map(DictionaryPanelToken.init(native:))
    let active = tokens.firstIndex { $0.text == "permission" }!
    func state(_ word: DictionaryPanelWord?, activeIndex: Int = active, loading: Bool = false) -> DictionaryPanelViewState {
        .init(query: sentence, sourceLanguage: .english, targetLanguage: .chinese, mode: .sentence, isLoading: loading, word: word,
              sentence: .init(source: sentence, translation: "录制会议需要获得许可。开始之前请先请求许可。", tokens: tokens, activeTokenIndex: activeIndex),
              aiAdditions: word?.examples.isEmpty == false ? [context] : [])
    }
    func essentialVisible(_ name: String, expectedMeanings: Int = 3, expectedTranslations: Int = 2) throws {
        content.layoutSubtreeIfNeeded()
        guard let scroll = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first else {
            throw DictionaryPanelCheckFailure(description: "Missing default viewport")
        }
        let fields = panelDescendants(content).compactMap { $0 as? NSTextField }
        let essentials = fields.filter {
            $0.accessibilityIdentifier() == "dictionary.pronunciation"
            || $0.accessibilityLabel()?.hasPrefix("Meaning ") == true && $0.accessibilityLabel()?.contains(":") == true
            || $0.accessibilityLabel()?.hasPrefix("Example 1:") == true
            || $0.accessibilityLabel()?.hasPrefix("Example 2:") == true
            || $0.accessibilityLabel()?.hasPrefix("Example translation ") == true
        }
        for view in essentials {
            let bounds = view.convert(view.bounds, to: scroll.contentView)
            try requirePanel(scroll.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                             "\(name): essential \(view.accessibilityLabel() ?? "") lies outside viewport: \(bounds) in \(scroll.contentView.bounds)")
        }
        try requirePanel(essentials.count == expectedMeanings + expectedTranslations + 3, "\(name): default must contain \(expectedMeanings) meanings, pronunciation, two examples and \(expectedTranslations) translations")
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 16, dy: 16).height ?? 10000
        try requirePanel(window.frame.height <= screenHeight + 0.5, "\(name): panel exceeds screen margins")
    }
    let short = DictionaryPanelWord(originalText: "We", headword: "we", meanings: [.init(definition: "The speaker and one or more other people.")])
    panel.update(state: state(short, activeIndex: 0))
    let shortHeight = window.frame.height
    let initialTop = window.frame.maxY
    panel.update(state: state(permission))
    try essentialVisible("short first token to permission")
    try requirePanel(window.frame.height > shortHeight && abs(window.frame.maxY - initialTop) <= 0.5,
                     "Later word did not grow downward while keeping source stationary")
    try savePanelPreview(window, name: "permission-sentence-620", subdirectory: "default-visibility")

    // New query starts from a native/cache result before AI examples and reading arrive.
    let partial = DictionaryPanelWord(originalText: "permission", headword: "permission", partOfSpeech: "noun", meanings: Array(permission.meanings.prefix(1)))
    panel.update(state: .init(query: "permission", sourceLanguage: .english, targetLanguage: .chinese, mode: .word, word: partial))
    let partialHeight = window.frame.height
    panel.update(state: .init(query: "permission", sourceLanguage: .english, targetLanguage: .chinese, mode: .word, word: permission, aiAdditions: [context]))
    try essentialVisible("late examples and reading")
    try requirePanel(window.frame.height > partialHeight, "Late enrichment retained the partial entry height")
    try savePanelPreview(window, name: "permission-word-620", subdirectory: "default-visibility")
    let height = window.frame.height
    panel.update(state: .init(query: "permission", sourceLanguage: .english, mode: .word, isLoading: true))
    try requirePanel(abs(window.frame.height - height) <= 0.5, "Routine loading shrank the default viewport")
    panel.update(state: .init(query: "permission retry", sourceLanguage: .english, mode: .word, errorMessage: "Dictionary service is unavailable."))
    let errorHeight = window.frame.height
    panel.update(state: .init(query: "permission retry", sourceLanguage: .english, targetLanguage: .chinese, mode: .word, word: permission, aiAdditions: [context]))
    try essentialVisible("retry after an early no-content error")
    try requirePanel(window.frame.height > errorHeight, "An early empty error consumed content sizing")
    guard let ai = panelDescendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel()?.hasPrefix("AI addition:") == true }),
          let outer = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first,
          let document = outer.documentView,
          let aiDisclosure = panelControl(content, identifier: "dictionary.context.disclosure") as? NSButton,
          let exampleDisclosure = panelControl(content, identifier: "dictionary.examples.disclosure") as? NSButton else {
        throw DictionaryPanelCheckFailure(description: "Full AI context or additional example disclosure is missing")
    }
    try requirePanel(document.bounds.contains(ai.convert(ai.bounds, to: document)), "Essential sizing cut supporting AI context out of the scroll document")
    try sendPanelAction(aiDisclosure, named: "expand AI context")
    let fullAI = panelDescendants(content).compactMap({ $0 as? NSTextField }).first { $0.accessibilityLabel()?.hasPrefix("AI addition:") == true }!
    try requirePanel(fullAI.frame.height > ai.frame.height, "AI expansion did not reveal its retained text")
    try sendPanelAction(exampleDisclosure, named: "expand examples")
    try requirePanel(panelDescendants(content).contains { $0.accessibilityLabel()?.hasPrefix("Example 3:") == true }, "Extra examples were discarded")

    let longSource = Array(repeating: "Please ask for permission before recording the meeting.", count: 18).joined(separator: "\n")
    let longTokens = DictionaryLanguageService.tokenize(longSource, language: .english).map(DictionaryPanelToken.init(native:))
    let lastPermission = longTokens.lastIndex { $0.text == "permission" }!
    let longTranslation = Array(repeating: "录制会议之前请先征得同意。", count: 18).joined(separator: "\n")
    let longState = DictionaryPanelViewState(query: longSource, sourceLanguage: .english, targetLanguage: .chinese,
        mode: .sentence, word: permission,
        sentence: .init(source: longSource, translation: longTranslation, tokens: longTokens, activeTokenIndex: lastPermission), aiAdditions: [context])
    panel.update(state: longState)
    try essentialVisible("long source, translation and AI context")
    guard let sourcePreview = panelControl(content, identifier: "dictionary.sentence.preview") as? NSScrollView,
          let retainedSource = sourcePreview.documentView as? NSTextView,
          let sourceDisclosure = panelControl(content, identifier: "dictionary.sentence.disclosure") as? NSButton else {
        throw DictionaryPanelCheckFailure(description: "Long sentence context lacks accessible expansion")
    }
    try requirePanel(retainedSource.string == longSource && retainedSource.frame.height > sourcePreview.frame.height,
                     "Compact source changed exact source or discarded its lines")
    guard let manager = retainedSource.layoutManager, let container = retainedSource.textContainer else { return }
    let activeGlyphs = manager.glyphRange(forCharacterRange: longTokens[lastPermission].utf16Range, actualCharacterRange: nil)
    let activeBounds = manager.boundingRect(forGlyphRange: activeGlyphs, in: container)
    try requirePanel(sourcePreview.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(activeBounds),
                     "Compact sentence preview hid the active repeated word")
    guard let counter = panelDescendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Current sentence token" }) else {
        throw DictionaryPanelCheckFailure(description: "Long sentence counter is missing")
    }
    let counterWidth = ceil((counter.stringValue as NSString).size(withAttributes: [.font: counter.font!]).width)
    try requirePanel(counter.stringValue == "140 / 144" && counter.cell!.drawingRect(forBounds: counter.bounds).width >= counterWidth + 4
                     && counter.frame.width >= ceil(counter.cell!.cellSize.width),
                     "Long sentence counter truncates its full current/total index")
    try savePanelPreview(window, name: "permission-long-source-620", subdirectory: "default-visibility")
    let previewHeight = window.frame.height
    try sendPanelAction(sourceDisclosure, named: "expand exact sentence context")
    let expandedSource = panelDescendants(content).compactMap({ $0 as? NSTextView }).first { $0.accessibilityLabel() == "Sentence source" }!
    try requirePanel(expandedSource.string == longSource && panelControl(content, identifier: "dictionary.sentence.preview") == nil,
                     "Sentence expansion failed to expose all exact source text")
    try requirePanel(abs(window.frame.height - previewHeight) <= 0.5, "Sentence disclosure jumped the window")

    window.setContentSize(NSSize(width: 380, height: 320))
    panel.update(state: .init(query: "permission narrow", sourceLanguage: .english, targetLanguage: .chinese, mode: .word, word: permission, aiAdditions: [context]))
    content.layoutSubtreeIfNeeded()
    try essentialVisible("permission word at 380 points")
    try savePanelPreview(window, name: "permission-word-380", subdirectory: "default-visibility")
    let narrowHeight = window.frame.height
    window.setContentSize(NSSize(width: 380, height: 320))
    panel.update(state: .init(query: "permission narrow", sourceLanguage: .english, targetLanguage: .chinese, mode: .word, word: permission, aiAdditions: [context]))
    guard let capped = panelDescendants(content).compactMap({ $0 as? NSScrollView }).first, let cappedDocument = capped.documentView else { return }
    try requirePanel(abs(window.frame.height - 320) <= 0.5 && narrowHeight > 320,
                     "Deliberately shortened viewport was enlarged again")
    try requirePanel(cappedDocument.frame.height > capped.contentView.bounds.height, "Small viewport lost access to scrollable detail")
    for label in panelDescendants(content).compactMap({ $0 as? NSTextField }).filter({ $0.accessibilityLabel()?.hasPrefix("Example ") == true }) {
        try requirePanel(cappedDocument.bounds.contains(label.convert(label.bounds, to: cappedDocument)), "Capped panel discarded example text")
        try requirePanel((label.font?.pointSize ?? 0) >= 12.5, "Narrow fixture shrank type to force content to fit")
    }
    capped.contentView.scroll(to: NSPoint(x: 0, y: 100))
    capped.reflectScrolledClipView(capped.contentView)
    let beforeDisclosureOrigin = capped.contentView.bounds.origin
    let beforeDisclosureTop = window.frame.maxY
    if let contextDisclosure = panelControl(content, identifier: "dictionary.context.disclosure") as? NSButton {
        try sendPanelAction(contextDisclosure, named: "expand AI context while scrolled")
    }
    try requirePanel(capped.contentView.bounds.origin == beforeDisclosureOrigin
                     && abs(window.frame.maxY - beforeDisclosureTop) <= 0.5 && abs(window.frame.height - 320) <= 0.5,
                     "Manual disclosure lost intentional scroll or resized the window")
    capped.contentView.scroll(to: .zero)
    capped.reflectScrolledClipView(capped.contentView)
    try savePanelPreview(window, name: "permission-capped-380", subdirectory: "default-visibility")

    let longDefinition = String(repeating: "Permission is consent granted by the responsible person. ", count: 12)
    let longExample = String(repeating: "You must ask for permission before using this material. ", count: 10)
    let verbose = DictionaryPanelWord(originalText: "permission", headword: "permission", phonetic: permission.phonetic,
        meanings: (1...3).map { .init(definition: "Meaning \($0). " + longDefinition) },
        examples: [.init(source: longExample, translation: longTranslation), .init(source: longExample + " Again.")])
    window.setContentSize(NSSize(width: 620, height: 320))
    panel.update(state: .init(query: "permission verbose", sourceLanguage: .english, mode: .word, word: verbose))
    guard let details = panelControl(content, identifier: "dictionary.entry.disclosure") as? NSButton,
          let previewMeaning = panelDescendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel()?.hasPrefix("Meaning 1:") == true }) else {
        throw DictionaryPanelCheckFailure(description: "Exceptionally long entry has no full-text disclosure")
    }
    try requirePanel(previewMeaning.toolTip?.contains(longDefinition) == true && previewMeaning.maximumNumberOfLines == 3,
                     "Long meaning preview silently discarded its full text")
    let verboseHeight = window.frame.height
    try essentialVisible("exceptionally long default entry", expectedTranslations: 1)
    try savePanelPreview(window, name: "permission-long-entry-620", subdirectory: "default-visibility")
    try sendPanelAction(details, named: "expand full entry text")
    let fullMeaning = panelDescendants(content).compactMap({ $0 as? NSTextField }).first { $0.accessibilityLabel()?.hasPrefix("Meaning 1:") == true }!
    try requirePanel(fullMeaning.maximumNumberOfLines == 0 && fullMeaning.frame.height > previewMeaning.frame.height,
                     "Full entry disclosure did not reveal retained text")
    try requirePanel(abs(window.frame.height - verboseHeight) <= 0.5, "Full entry disclosure resized the viewport")
    print("PASS measured default viewport contains pronunciation, three meanings and two translated examples after navigation and enrichment")
}
