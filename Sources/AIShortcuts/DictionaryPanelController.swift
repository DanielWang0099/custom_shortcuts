import AppKit
import AIShortcutsCore
import Foundation

// MARK: - Panel-facing models

public struct DictionarySourceLanguage: RawRepresentable, Hashable, CaseIterable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = normalized.isEmpty ? "auto" : normalized
    }

    public static let automatic = DictionarySourceLanguage(rawValue: "auto")
    public static let english = DictionarySourceLanguage(rawValue: "en")
    public static let spanish = DictionarySourceLanguage(rawValue: "es")
    public static let chinese = DictionarySourceLanguage(rawValue: "zh")
    public static let traditionalChinese = DictionarySourceLanguage(rawValue: "zh-hant")
    public static let japanese = DictionarySourceLanguage(rawValue: "ja")

    public static var priorityCases: [DictionarySourceLanguage] {
        [.automatic, .english, .spanish, .chinese, .traditionalChinese, .japanese]
    }

    public static var allCases: [DictionarySourceLanguage] {
        var result = priorityCases
        let languageCodes: [String]
        if #available(macOS 13.0, *) {
            languageCodes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
        } else {
            languageCodes = Locale.isoLanguageCodes
        }
        let additional = languageCodes.compactMap { code -> DictionarySourceLanguage? in
            let value = DictionarySourceLanguage(rawValue: code)
            return result.contains(value) ? nil : value
        }
        result.append(contentsOf: additional.sorted { $0.displayName < $1.displayName })
        return result
    }

    public var displayName: String {
        if rawValue.lowercased() == "zh-hant" { return "繁體中文" }
        return switch canonicalCode {
        case "auto": "Auto"
        case "en": "English"
        case "es": "Spanish"
        case "zh": "简体中文"
        case "ja": "日本語"
        default: Locale.current.localizedString(forLanguageCode: rawValue)?.capitalized ?? rawValue
        }
    }

    public var shortDisplayName: String {
        canonicalCode == "auto" ? "Auto" : rawValue
    }

    public var canonicalCode: String {
        switch rawValue.lowercased() {
        case "auto", "und": "auto"
        case "en", "en-us", "en-gb": "en"
        case "es", "es-es", "es-mx": "es"
        case "zh", "zh-hans", "zh-hant", "cmn": "zh"
        case "ja", "ja-jp": "ja"
        default: rawValue
        }
    }

    public var isAutomatic: Bool { canonicalCode == "auto" }
}

public enum DictionaryTargetLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"
    case chinese = "zh"
    case traditionalChinese = "zh-hant"
    case japanese = "ja"

    public init?(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "en", "en-us", "english": self = .english
        case "es", "es-es", "spanish", "español": self = .spanish
        case "zh", "zh-cn", "zh-hans", "ch", "chinese", "中文", "简体中文": self = .chinese
        case "zh-hant", "zh-tw", "zh-hk", "traditional chinese", "繁體中文", "繁体中文": self = .traditionalChinese
        case "ja", "ja-jp", "japanese", "日本語": self = .japanese
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .chinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        }
    }

    public var sourceLanguage: DictionarySourceLanguage {
        switch self {
        case .english: .english
        case .spanish: .spanish
        case .chinese: .chinese
        case .traditionalChinese: .traditionalChinese
        case .japanese: .japanese
        }
    }
}

public enum DictionaryPanelMode: Equatable {
    case manual
    case word
    case sentence
}

/// Controls how the panel is presented. Production uses `.active`; the
/// offscreen mode is for native UI fixtures that must exercise rendering and
/// focus without activating or flashing the user's desktop.
public enum DictionaryPanelPresentationMode: Sendable {
    case active
    case offscreenTest
}

public struct DictionaryPanelToken: Equatable {
    public let text: String
    public let utf16Range: NSRange
    public let headword: String?
    /// The language resolved for this token when automatic source selection
    /// is active.  Sentence lookups can contain multiple scripts, so callers
    /// must not infer a token's lookup or speech language from the sentence's
    /// dominant language.
    public let sourceLanguage: DictionarySourceLanguage
    public let isPunctuation: Bool
    public let isWhitespace: Bool

    public init(
        text: String,
        utf16Range: NSRange = NSRange(location: NSNotFound, length: 0),
        headword: String? = nil,
        sourceLanguage: DictionarySourceLanguage = .automatic,
        isPunctuation: Bool = false,
        isWhitespace: Bool = false
    ) {
        self.text = text
        self.utf16Range = utf16Range
        self.headword = headword
        self.sourceLanguage = sourceLanguage
        self.isPunctuation = isPunctuation
        self.isWhitespace = isWhitespace
    }

    public init(native token: DictionaryNativeToken) {
        self.init(
            text: token.text,
            utf16Range: token.utf16Range,
            headword: token.lemma,
            sourceLanguage: token.language ?? .automatic,
            isPunctuation: token.isPunctuation,
            isWhitespace: token.isWhitespace
        )
    }
}

public struct DictionaryPanelMeaning: Equatable {
    public let definition: String
    public let translation: String?
    public let isAIAddition: Bool

    public init(
        definition: String,
        translation: String? = nil,
        isAIAddition: Bool = false
    ) {
        self.definition = definition
        self.translation = translation
        self.isAIAddition = isAIAddition
    }
}

public struct DictionaryPanelExample: Equatable {
    public let source: String
    public let translation: String?
    public let language: DictionarySourceLanguage
    public let isAIAddition: Bool

    public init(
        source: String,
        translation: String? = nil,
        language: DictionarySourceLanguage = .automatic,
        isAIAddition: Bool = false
    ) {
        self.source = source
        self.translation = translation
        self.language = language
        self.isAIAddition = isAIAddition
    }
}

public struct DictionaryPanelWord: Equatable {
    public let originalText: String
    public let headword: String
    public let partOfSpeech: String?
    public let phonetic: String?
    public let reading: String?
    public let isAIReading: Bool
    public let meanings: [DictionaryPanelMeaning]
    public let examples: [DictionaryPanelExample]
    public let sourceName: String?
    public let sourceURL: URL?

    public init(
        originalText: String,
        headword: String,
        partOfSpeech: String? = nil,
        phonetic: String? = nil,
        reading: String? = nil,
        isAIReading: Bool = false,
        meanings: [DictionaryPanelMeaning] = [],
        examples: [DictionaryPanelExample] = [],
        sourceName: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.originalText = originalText
        self.headword = headword
        self.partOfSpeech = partOfSpeech
        self.phonetic = phonetic
        self.reading = reading
        self.isAIReading = isAIReading
        self.meanings = meanings
        self.examples = examples
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }
}

public struct DictionaryPanelSentence: Equatable {
    public let source: String
    public let translation: String?
    public let tokens: [DictionaryPanelToken]
    public let activeTokenIndex: Int
    public let activeRange: NSRange?

    public init(
        source: String,
        translation: String? = nil,
        tokens: [DictionaryPanelToken] = [],
        activeTokenIndex: Int = 0,
        activeRange: NSRange? = nil
    ) {
        self.source = source
        self.translation = translation
        self.tokens = tokens
        self.activeTokenIndex = max(0, min(activeTokenIndex, max(0, tokens.count - 1)))
        self.activeRange = activeRange
    }
}

public struct DictionaryPanelViewState: Equatable {
    public let query: String
    public let sourceLanguage: DictionarySourceLanguage
    /// The language resolved for the current query while the source popup is
    /// still set to Auto. This keeps the override visible to the coordinator
    /// without forcing the popup away from its automatic selection.
    public let detectedSourceLanguage: DictionarySourceLanguage?
    public let targetLanguage: DictionaryTargetLanguage
    public let mode: DictionaryPanelMode
    public let presentationMode: DictionaryPresentationMode
    public let paragraphTranslation: String?
    public let isLoading: Bool
    public let errorMessage: String?
    public let word: DictionaryPanelWord?
    public let sentence: DictionaryPanelSentence?
    public let aiAdditions: [String]
    public let attributionName: String?
    public let attributionURL: URL?

    public init(
        query: String,
        sourceLanguage: DictionarySourceLanguage = .automatic,
        detectedSourceLanguage: DictionarySourceLanguage? = nil,
        targetLanguage: DictionaryTargetLanguage = .english,
        mode: DictionaryPanelMode = .manual,
        presentationMode: DictionaryPresentationMode = .dictionary,
        paragraphTranslation: String? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        word: DictionaryPanelWord? = nil,
        sentence: DictionaryPanelSentence? = nil,
        aiAdditions: [String] = [],
        attributionName: String? = nil,
        attributionURL: URL? = nil
    ) {
        self.query = query
        self.sourceLanguage = sourceLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.targetLanguage = targetLanguage
        self.mode = mode
        self.presentationMode = presentationMode
        self.paragraphTranslation = paragraphTranslation
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.word = word
        self.sentence = sentence
        self.aiAdditions = aiAdditions
        self.attributionName = attributionName
        self.attributionURL = attributionURL
    }

    public static var empty: DictionaryPanelViewState {
        DictionaryPanelViewState(query: "")
    }
}

/// A small UI-facing projection of a stored lookup. The coordinator can map
/// its bounded history store into this value without making the AppKit panel
/// depend on the store's persistence details.
public struct DictionaryPanelHistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let query: String
    public let sourceLanguage: DictionarySourceLanguage
    public let detectedSourceLanguage: DictionarySourceLanguage?
    public let targetLanguage: DictionaryTargetLanguage
    public let presentationMode: DictionaryPresentationMode
    public let lookedUpAt: Date

    public init(
        id: UUID = UUID(),
        query: String,
        sourceLanguage: String = DictionarySourceLanguage.automatic.rawValue,
        detectedSourceLanguage: String? = nil,
        targetLanguage: String = DictionaryTargetLanguage.english.rawValue,
        presentationMode: DictionaryPresentationMode = .dictionary,
        lookedUpAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.sourceLanguage = DictionarySourceLanguage(rawValue: sourceLanguage)
        if let detectedSourceLanguage, !detectedSourceLanguage.isEmpty {
            self.detectedSourceLanguage = DictionarySourceLanguage(rawValue: detectedSourceLanguage)
        } else {
            self.detectedSourceLanguage = nil
        }
        self.targetLanguage = DictionaryTargetLanguage(rawValue: targetLanguage) ?? .english
        self.presentationMode = presentationMode
        self.lookedUpAt = lookedUpAt
    }

    public init(
        id: UUID = UUID(),
        query: String,
        sourceLanguage: DictionarySourceLanguage,
        detectedSourceLanguage: DictionarySourceLanguage? = nil,
        targetLanguage: DictionaryTargetLanguage,
        presentationMode: DictionaryPresentationMode = .dictionary,
        lookedUpAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.sourceLanguage = sourceLanguage
        self.detectedSourceLanguage = detectedSourceLanguage
        self.targetLanguage = targetLanguage
        self.presentationMode = presentationMode
        self.lookedUpAt = lookedUpAt
    }
}

private enum DictionaryPanelLayout {
    static let panelWidth: CGFloat = 620
    static let panelHeight: CGFloat = 520
    static let compactPanelHeight: CGFloat = 320
    static let minimumPanelHeight: CGFloat = 300
    static let outerInset: CGFloat = 22
    static let headerInset: CGFloat = 22
    static let headerY: CGFloat = 12
    static let headerControlHeight: CGFloat = 32
    static let searchY: CGFloat = 57
    static let searchHeight: CGFloat = 52
    static let searchInset: CGFloat = 22
    static let scrollY: CGFloat = 121
    static let contentInset: CGFloat = 4
    static let bodyScrollerGap: CGFloat = 6
    static let controlGap: CGFloat = 6
    static let lookupButtonWidth: CGFloat = 32
    static let lookupClearWidth: CGFloat = 30
    static let lookupTrailingInset: CGFloat = 14
    static let lookupFieldInset: CGFloat = 14
    static let sectionGap: CGFloat = 12
    static let bodyBottomInset: CGFloat = 16
    static let exampleInset: CGFloat = 0
    static let historyWidth: CGFloat = 344
    static let historyRowHeight: CGFloat = 58
}

/// Screen geometry is injected into the panel placement policy so native
/// fixtures can exercise the production window calculations entirely beyond
/// the desktop's visible monitors.
struct DictionaryPanelScreenGeometry: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
}

/// Tracks only user placement and human activity. Programmatic frame changes
/// never call `recordUserMove`, and async rendering never refreshes its clock.
struct DictionaryPanelPlacementSession {
    static let inactivityTimeout: TimeInterval = 600

    private(set) var lastActivity: TimeInterval?
    private(set) var isUserMoved = false
    private(set) var preferredScreenFrame: NSRect?
    private var pendingExpiry = false

    @discardableResult
    mutating func beginOperation(at time: TimeInterval, activeScreenFrame: NSRect?) -> Bool {
        let expired = pendingExpiry
            || (lastActivity.map { time - $0 >= Self.inactivityTimeout } ?? false)
        pendingExpiry = false
        if expired {
            isUserMoved = false
            preferredScreenFrame = nil
        }
        if preferredScreenFrame == nil {
            preferredScreenFrame = activeScreenFrame
        }
        lastActivity = time
        return expired
    }

    mutating func recordHumanActivity(at time: TimeInterval) {
        if let lastActivity, time - lastActivity >= Self.inactivityTimeout {
            pendingExpiry = true
        }
        lastActivity = time
    }

    mutating func recordUserMove(at time: TimeInterval, screenFrame: NSRect?) {
        isUserMoved = true
        pendingExpiry = false
        lastActivity = time
        if let screenFrame {
            preferredScreenFrame = screenFrame
        }
    }

    mutating func retainScreen(_ frame: NSRect?) {
        if let frame {
            preferredScreenFrame = frame
        }
    }

    mutating func reset() {
        lastActivity = nil
        isUserMoved = false
        preferredScreenFrame = nil
        pendingExpiry = false
    }
}

private enum DictionaryPanelPlacementGeometry {
    static func frame(
        current: NSRect,
        size: NSSize,
        center: Bool,
        visibleFrame: NSRect
    ) -> NSRect {
        let usable = visibleFrame.insetBy(dx: 16, dy: 16)
        let width = min(max(1, size.width), max(1, usable.width))
        let height = min(max(1, size.height), max(1, usable.height))
        let minimumX = usable.minX
        let minimumY = usable.minY
        let maximumX = max(minimumX, usable.maxX - width)
        let maximumY = max(minimumY, usable.maxY - height)
        let requestedX = center ? usable.midX - width / 2 : current.minX
        let requestedY = center ? usable.midY - height / 2 : current.maxY - height
        return NSRect(
            x: min(max(requestedX, minimumX), maximumX),
            y: min(max(requestedY, minimumY), maximumY),
            width: width,
            height: height
        )
    }
}

/// Dictionary uses a couple of stronger roles for small text on raised
/// graphite surfaces. Keeping them local avoids changing the shared shortcut
/// palette while making the lookup placeholder, dense metadata, and purple
/// labels readable at the panel's compact sizes.
@MainActor
private enum DictionaryPanelStyle {
    static let placeholderTextColor = ShortcutUIStyle.secondaryTextColor
    static let accentTextColor = NSColor(
        srgbRed: 0.635,
        green: 0.600,
        blue: 1.0,
        alpha: 1
    )
    static let focusBorderColor = ShortcutUIStyle.accentColor
    static let denseMetadataFont = NSFont.systemFont(ofSize: 12)
}

// MARK: - Panel window and flow layout

private final class DictionaryPanelWindow: NSPanel {
    weak var owner: DictionaryPanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        owner?.cancelFromUser()
    }

    override func performClose(_ sender: Any?) {
        owner?.cancelFromUser()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if owner?.handlePanelKeyEvent(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handlePanelKeyEvent(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        owner?.recordPanelInput(event)
        if event.type == .keyDown, event.keyCode == 48,
           owner?.handlePanelKeyEvent(event) == true {
            return
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp {
            owner?.finishPanelWindowDrag()
        }
    }
}

private final class DictionaryPanelSurfaceView: NSView {
    override var isFlipped: Bool { true }
}

private final class DictionarySearchSurface: NSView {
    var onHover: ((Bool) -> Void)?
    var lineOpacity: CGFloat = 0
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if lineOpacity > 0 {
            ShortcutUIStyle.contentBorderColor.withAlphaComponent(
                ShortcutUIStyle.contentBorderColor.alphaComponent * lineOpacity
            ).setFill()
            NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
        }
    }
}

/// Borderless native buttons still need feedback when the pointer is over
/// them. This keeps hover treatment inside the established graphite/purple
/// palette while leaving AppKit's keyboard focus ring available.
private final class DictionaryHoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var normalBackgroundColor = NSColor.clear
    private var hoverBackgroundColor = NSColor.clear
    private var pressedBackgroundColor = NSColor.clear
    private var disabledBackgroundColor = NSColor.clear

    func configureHover(
        normal: NSColor,
        hover: NSColor,
        pressed: NSColor? = nil,
        disabled: NSColor? = nil
    ) {
        normalBackgroundColor = normal
        hoverBackgroundColor = hover
        pressedBackgroundColor = pressed ?? hover.withAlphaComponent(min(1, hover.alphaComponent + 0.10))
        disabledBackgroundColor = disabled ?? normal.withAlphaComponent(normal.alphaComponent * 0.55)
        wantsLayer = true
        applyBackground()
    }

    override var isHighlighted: Bool {
        didSet { applyBackground() }
    }

    override var isEnabled: Bool {
        didSet { applyBackground() }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = next
        addTrackingArea(next)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyBackground()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyBackground()
        super.mouseExited(with: event)
    }

    private func applyBackground() {
        let color: NSColor
        if !isEnabled {
            color = disabledBackgroundColor
        } else if isHighlighted {
            color = pressedBackgroundColor
        } else if isHovered {
            color = hoverBackgroundColor
        } else {
            color = normalBackgroundColor
        }
        layer?.backgroundColor = color.cgColor
    }
}

private final class DictionaryLanguagePopupCell: NSPopUpButtonCell {
    var compactTitle: String?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let background = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (isHighlighted ? ShortcutUIStyle.accentColor.withAlphaComponent(0.22) : ShortcutUIStyle.raisedSurfaceColor).setFill()
        background.fill()
        ShortcutUIStyle.contentBorderColor.setStroke()
        background.lineWidth = 1
        background.stroke()
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: compactTitle ?? title, attributes: [
            .font: font, .foregroundColor: ShortcutUIStyle.primaryTextColor, .paragraphStyle: paragraph,
        ])
        let height = ceil(font.ascender - font.descender)
        text.draw(in: NSRect(x: cellFrame.minX + 10, y: cellFrame.midY - height / 2,
                             width: max(0, cellFrame.width - 31), height: height))
        let chevron = NSBezierPath()
        let x = cellFrame.maxX - 14
        chevron.move(to: NSPoint(x: x - 3, y: cellFrame.midY - 1.5))
        chevron.line(to: NSPoint(x: x, y: cellFrame.midY + 1.5))
        chevron.line(to: NSPoint(x: x + 3, y: cellFrame.midY - 1.5))
        chevron.lineWidth = 1.3
        ShortcutUIStyle.secondaryTextColor.setStroke()
        chevron.stroke()
    }
}

private final class DictionaryHistoryQueryCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: self.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: ShortcutUIStyle.primaryTextColor, .paragraphStyle: paragraph,
        ])
        let rect = controlView.bounds.insetBy(dx: 2, dy: 1)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return rect
    }
}

private final class DictionaryCenteredTextFieldCell: NSTextFieldCell {
    private func centeredTextRect(for rect: NSRect) -> NSRect {
        let textHeight = min(
            rect.height,
            max(18, ceil((font?.ascender ?? 15) - (font?.descender ?? -4)))
        )
        return NSRect(
            x: rect.minX,
            y: rect.midY - textHeight / 2,
            width: rect.width,
            height: textHeight
        )
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: super.drawingRect(forBounds: rect))
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredTextRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredTextRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class DictionarySentenceTextView: NSTextView {
    private static let tokenAttribute = NSAttributedString.Key("AIShortcuts.DictionaryPanelTokenIndex")

    private let tokens: [DictionaryPanelToken]
    private let onSelect: (DictionaryPanelToken) -> Void
    private var activeRange: NSRange?
    private var dragStartIndex: Int?
    private var dragEndIndex: Int?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        tokens = []
        onSelect = { _ in }
        super.init(frame: frameRect, textContainer: container)
    }

    init(
        tokens: [DictionaryPanelToken],
        activeIndex: Int,
        source: String,
        selectedRange: NSRange? = nil,
        onSelect: @escaping (DictionaryPanelToken) -> Void
    ) {
        self.tokens = tokens
        self.onSelect = onSelect
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: textContainer)

        isEditable = false
        isSelectable = true
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        backgroundColor = .clear
        textColor = ShortcutUIStyle.primaryTextColor
        font = .systemFont(ofSize: 15)
        textContainerInset = NSSize(width: 0, height: 0)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        selectedTextAttributes = [
            .backgroundColor: NSColor.clear,
            .foregroundColor: ShortcutUIStyle.primaryTextColor,
        ]
        setAccessibilityLabel("Sentence source")
        setAccessibilityHelp("Click a word or drag across words to look up a phrase.")
        setAccessibilityValue(source)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let baseFont = NSFont.systemFont(ofSize: 15)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: baseFont,
                .foregroundColor: ShortcutUIStyle.secondaryTextColor,
                .paragraphStyle: paragraph,
            ]
        )

        let sourceNSString = source as NSString
        for (index, token) in tokens.enumerated() {
            let range = token.utf16Range
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location <= sourceNSString.length,
                  NSMaxRange(range) <= sourceNSString.length,
                  sourceNSString.substring(with: range) == token.text
            else { continue }

            var attributes: [NSAttributedString.Key: Any] = [
                // Keep the line metrics identical while the active token
                // changes. The purple background and foreground already give
                // the selected word emphasis without moving the source view.
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: index == activeIndex
                    ? ShortcutUIStyle.primaryTextColor
                    : (token.isWhitespace ? ShortcutUIStyle.secondaryTextColor : ShortcutUIStyle.primaryTextColor),
                Self.tokenAttribute: NSNumber(value: index),
            ]
            if index == activeIndex {
                activeRange = range
                attributes[NSAttributedString.Key("AIShortcuts.DictionaryActiveToken")] = true
            }
            attributed.setAttributes(attributes, range: range)
        }
        textStorage.setAttributedString(attributed)
        if let selectedRange, selectedRange.location != NSNotFound,
           NSMaxRange(selectedRange) <= sourceNSString.length { activeRange = selectedRange }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer = self.textContainer,
              let layoutManager = self.layoutManager
        else { return 30 }
        textContainer.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return max(30, ceil(used.height + textContainerInset.height * 2 + 2))
    }

    func previewHeight(maximumLines: Int) -> CGFloat {
        guard let layoutManager, textContainer != nil else { return 30 }
        var lines = 0
        var bottom: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, _, stop in
            bottom = rect.maxY
            lines += 1
            if lines >= maximumLines { stop.pointee = true }
        }
        return max(30, ceil(bottom + textContainerInset.height * 2 + 2))
    }

    func revealActiveToken() {
        guard let activeRange else { return }
        scrollRangeToVisible(activeRange)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let activeRange, let layoutManager, let textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: activeRange, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                var padded = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -3, dy: -1)
                padded = padded.intersection(self.bounds)
                ShortcutUIStyle.accentColor.withAlphaComponent(0.24).setFill()
                NSBezierPath(roundedRect: padded, xRadius: 4, yRadius: 4).fill()
                DictionaryPanelStyle.accentTextColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: padded.minX + 3, y: padded.maxY - 2, width: max(0, padded.width - 6), height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            }
        }
        super.draw(dirtyRect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer else { return }
        for token in tokens where !token.isWhitespace && !token.isPunctuation {
            guard token.utf16Range.location != NSNotFound,
                  NSMaxRange(token.utf16Range) <= (string as NSString).length else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: token.utf16Range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), cursor: .pointingHand)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textContainer = self.textContainer,
              let layoutManager = self.layoutManager,
              let textStorage = self.textStorage,
              textStorage.length > 0
        else { return }

        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(textPoint), characterIndex < textStorage.length,
              let number = textStorage.attribute(
                  Self.tokenAttribute,
                  at: characterIndex,
                  effectiveRange: nil
              ) as? NSNumber,
              tokens.indices.contains(number.intValue),
              !tokens[number.intValue].isWhitespace, !tokens[number.intValue].isPunctuation
        else { return }

        window?.makeFirstResponder(self)
        dragStartIndex = number.intValue
        dragEndIndex = number.intValue
        activeRange = tokens[number.intValue].utf16Range
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        let character = characterIndexForInsertion(at: point)
        let words = tokens.indices.filter { !tokens[$0].isWhitespace && !tokens[$0].isPunctuation }
        let containingWord = words.first { NSLocationInRange(character, tokens[$0].utf16Range) }
        guard let end = containingWord ?? words.min(by: {
            abs(tokens[$0].utf16Range.location - character) < abs(tokens[$1].utf16Range.location - character)
        }) else { return }
        dragEndIndex = end
        activeRange = NSUnionRange(tokens[start].utf16Range, tokens[end].utf16Range)
        needsDisplay = true
        _ = autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStartIndex, let end = dragEndIndex else { return }
        dragStartIndex = nil
        dragEndIndex = nil
        if start == end {
            onSelect(tokens[start])
        } else {
            let range = NSUnionRange(tokens[start].utf16Range, tokens[end].utf16Range)
            let phrase = (string as NSString).substring(with: range)
            onSelect(DictionaryPanelToken(text: phrase, utf16Range: range, headword: phrase,
                                          sourceLanguage: DictionaryLanguageService.detect(phrase)))
        }
    }
}

@MainActor
private final class DictionaryHistoryPopoverController: NSViewController {
    private var items: [DictionaryPanelHistoryItem]
    private var errorMessage: String?
    private let onSelect: (DictionaryPanelHistoryItem) -> Void
    private let onDelete: (UUID) -> Void
    private let onClear: () -> Void

    private let listScrollView = NSScrollView(frame: .zero)
    private let listDocument = DictionaryPanelSurfaceView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let clearButton = DictionaryHoverButton(frame: .zero)
    private let cancelClearButton = DictionaryHoverButton(frame: .zero)
    private var rowIDs: [Int: UUID] = [:]
    private var isConfirmingClear = false

    init(
        items: [DictionaryPanelHistoryItem],
        errorMessage: String? = nil,
        onSelect: @escaping (DictionaryPanelHistoryItem) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.items = items
        self.errorMessage = errorMessage
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onClear = onClear
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: DictionaryPanelLayout.historyWidth, height: 150)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: DictionaryPanelLayout.historyWidth,
            height: preferredContentSize.height
        ))
        root.wantsLayer = true
        root.layer?.backgroundColor = ShortcutUIStyle.shellColor.cgColor
        root.setAccessibilityLabel("Dictionary history")
        root.setAccessibilityIdentifier("dictionary.history.popover")

        let title = NSTextField(labelWithString: "Recent lookups")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = ShortcutUIStyle.primaryTextColor
        title.frame = NSRect(x: 16, y: root.bounds.height - 34, width: 180, height: 20)
        title.setAccessibilityLabel("Recent lookups")

        clearButton.isBordered = false
        clearButton.focusRingType = .default
        clearButton.title = "Clear"
        clearButton.font = .systemFont(ofSize: 12, weight: .medium)
        clearButton.contentTintColor = DictionaryPanelStyle.accentTextColor
        clearButton.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.10)
        )
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.frame = NSRect(x: 262, y: root.bounds.height - 37, width: 66, height: 26)
        clearButton.setAccessibilityLabel("Clear dictionary history")
        clearButton.setAccessibilityIdentifier("dictionary.history.clear")
        clearButton.setAccessibilityHelp("Remove all recent dictionary lookups.")
        clearButton.toolTip = "Clear recent lookups"

        cancelClearButton.isBordered = false
        cancelClearButton.focusRingType = .default
        cancelClearButton.title = "Cancel"
        cancelClearButton.font = .systemFont(ofSize: 12, weight: .medium)
        cancelClearButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        cancelClearButton.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.10)
        )
        cancelClearButton.target = self
        cancelClearButton.action = #selector(cancelClearPressed(_:))
        cancelClearButton.frame = NSRect(x: 200, y: root.bounds.height - 37, width: 54, height: 26)
        cancelClearButton.setAccessibilityLabel("Cancel clearing dictionary history")
        cancelClearButton.setAccessibilityIdentifier("dictionary.history.clear.cancel")
        cancelClearButton.isHidden = true

        listScrollView.frame = NSRect(x: 10, y: 10, width: 324, height: root.bounds.height - 58)
        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.hasHorizontalScroller = false
        listScrollView.borderType = .noBorder
        listScrollView.scrollerStyle = .overlay
        listScrollView.documentView = listDocument
        listScrollView.setAccessibilityLabel("Recent dictionary lookups")
        listScrollView.setAccessibilityIdentifier("dictionary.history.list")

        statusLabel.font = DictionaryPanelStyle.denseMetadataFont
        statusLabel.textColor = ShortcutUIStyle.warningAccentColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Dictionary history status")
        statusLabel.setAccessibilityIdentifier("dictionary.history.status")
        statusLabel.isHidden = true

        root.addSubview(title)
        root.addSubview(statusLabel)
        root.addSubview(clearButton)
        root.addSubview(cancelClearButton)
        root.addSubview(listScrollView)
        view = root
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        clearButton.frame.origin = NSPoint(x: view.bounds.width - 82, y: view.bounds.height - 37)
        cancelClearButton.frame.origin = NSPoint(x: view.bounds.width - 144, y: view.bounds.height - 37)
        if let title = view.subviews.first(where: { ($0 as? NSTextField)?.stringValue == "Recent lookups" }) as? NSTextField {
            title.frame = NSRect(x: 16, y: view.bounds.height - 34,
                                 width: min(180, (isConfirmingClear ? cancelClearButton.frame.minX : clearButton.frame.minX) - 24), height: 20)
            title.lineBreakMode = .byTruncatingTail
        }
        statusLabel.frame = NSRect(x: 16, y: view.bounds.height - 56, width: view.bounds.width - 32, height: 18)
        listScrollView.frame = NSRect(x: 10, y: 10, width: max(1, view.bounds.width - 20),
                                     height: max(74, view.bounds.height - (statusLabel.isHidden ? 58 : 68)))
        let width = listScrollView.contentView.bounds.width
        listDocument.frame.size.width = width
        for row in listDocument.subviews {
            if items.isEmpty {
                row.frame = NSRect(x: 10, y: max(26, listScrollView.bounds.height / 2 - 11), width: width - 20, height: 22)
                continue
            }
            row.frame.size.width = width
            for child in row.subviews {
                if let button = child as? NSButton, button.accessibilityIdentifier().hasPrefix("dictionary.history.delete.") == true {
                    button.frame.origin.x = width - 32
                } else if child is NSButton || child is NSTextField {
                    child.frame.size.width = max(1, width - 42)
                }
            }
        }
    }

    func update(items: [DictionaryPanelHistoryItem], errorMessage: String? = nil) {
        self.items = items
        self.errorMessage = errorMessage
        reload()
    }

    private func reload() {
        guard isViewLoaded else { return }
        rowIDs.removeAll()
        for subview in listDocument.subviews {
            subview.removeFromSuperview()
        }

        let rowCount = min(items.count, 5)
        let hasError = !(errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        clearButton.isEnabled = !items.isEmpty || hasError
        clearButton.alphaValue = clearButton.isEnabled ? 1 : 0.45

        let baseHeight = items.isEmpty
            ? 150
            : min(360, 58 + CGFloat(rowCount) * DictionaryPanelLayout.historyRowHeight
                + CGFloat(max(0, rowCount - 1)) * 6)
        let contentHeight = min(360, baseHeight + (hasError ? 26 : 0))
        preferredContentSize = NSSize(width: DictionaryPanelLayout.historyWidth, height: contentHeight)
        view.setFrameSize(preferredContentSize)
        statusLabel.isHidden = !hasError
        statusLabel.stringValue = hasError ? (errorMessage ?? "") : ""
        statusLabel.toolTip = errorMessage
        statusLabel.frame = NSRect(
            x: 16,
            y: view.bounds.height - 56,
            width: max(160, view.bounds.width - 32),
            height: 18
        )
        listScrollView.frame = NSRect(
            x: 10,
            y: 10,
            width: view.bounds.width - 20,
            height: max(74, view.bounds.height - (hasError ? 68 : 58))
        )
        if let title = view.subviews.first(where: { ($0 as? NSTextField)?.stringValue == "Recent lookups" }) {
            title.frame.origin.y = view.bounds.height - 34
        }
        clearButton.frame.origin.y = view.bounds.height - 37
        cancelClearButton.frame.origin.y = view.bounds.height - 37

        guard !items.isEmpty else {
            isConfirmingClear = false
            clearButton.title = "Clear"
            cancelClearButton.isHidden = true
            let empty = NSTextField(labelWithString: "No recent lookups yet.")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = ShortcutUIStyle.secondaryTextColor
            empty.alignment = .center
            empty.frame = NSRect(
                x: 10,
                y: max(26, listScrollView.bounds.height / 2 - 11),
                width: max(120, listScrollView.bounds.width - 20),
                height: 22
            )
            empty.setAccessibilityLabel("No recent dictionary lookups")
            listDocument.addSubview(empty)
            listDocument.setFrameSize(NSSize(
                width: max(1, listScrollView.bounds.width),
                height: max(74, listScrollView.bounds.height)
            ))
            return
        }

        let rowWidth = listScrollView.contentView.bounds.width
        let rowGap: CGFloat = 4
        let totalHeight = CGFloat(items.count) * DictionaryPanelLayout.historyRowHeight
            + CGFloat(max(0, items.count - 1)) * rowGap
        let documentHeight = max(listScrollView.bounds.height, totalHeight)
        listDocument.setFrameSize(NSSize(width: rowWidth, height: documentHeight))
        for (index, item) in items.enumerated() {
            // The document view is flipped, so row zero starts at the top of
            // the visible list. Additional rows extend downward and become
            // reachable through the native scroller when needed.
            let y = CGFloat(index) * (DictionaryPanelLayout.historyRowHeight + rowGap)
            let row = DictionaryPanelSurfaceView(frame: NSRect(
                x: 0,
                y: y,
                width: rowWidth,
                height: DictionaryPanelLayout.historyRowHeight
            ))

            let query = DictionaryHoverButton(frame: .zero)
            query.cell = DictionaryHistoryQueryCell(textCell: Self.displayQuery(item.query))
            query.target = self
            query.action = #selector(selectPressed(_:))
            query.isBordered = false
            query.focusRingType = .default
            query.alignment = .left
            query.font = .systemFont(ofSize: 13.5, weight: .medium)
            query.contentTintColor = ShortcutUIStyle.primaryTextColor
            query.configureHover(
                normal: .clear,
                hover: ShortcutUIStyle.primaryTextColor.withAlphaComponent(0.08)
            )
            query.frame = NSRect(x: 6, y: 0, width: rowWidth - 42, height: 36)
            query.cell?.wraps = true
            query.cell?.usesSingleLineMode = false
            query.lineBreakMode = .byWordWrapping
            query.cell?.wraps = true
            query.tag = index
            query.toolTip = item.query
            query.setAccessibilityLabel("Reopen lookup \(item.query)")
            query.setAccessibilityIdentifier("dictionary.history.item.\(item.id.uuidString)")
            query.setAccessibilityHelp("Look up this query again.")

            let metadata = NSTextField(labelWithString: Self.metadata(for: item))
            metadata.font = DictionaryPanelStyle.denseMetadataFont
            metadata.textColor = ShortcutUIStyle.secondaryTextColor
            metadata.frame = NSRect(x: 6, y: 38, width: rowWidth - 42, height: 17)
            metadata.lineBreakMode = .byTruncatingTail
            metadata.toolTip = Self.fullMetadata(for: item)
            metadata.setAccessibilityLabel("Lookup details \(Self.fullMetadata(for: item))")

            let remove = DictionaryHoverButton(frame: NSRect(x: rowWidth - 32, y: 13, width: 28, height: 28))
            remove.isBordered = false
            remove.focusRingType = .default
            remove.image = NSImage(
                systemSymbolName: "trash",
                accessibilityDescription: "Delete lookup"
            )?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            remove.imagePosition = .imageOnly
            remove.contentTintColor = ShortcutUIStyle.secondaryTextColor
            remove.configureHover(
                normal: .clear,
                hover: ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.12)
            )
            remove.target = self
            remove.action = #selector(deletePressed(_:))
            remove.tag = index
            remove.setAccessibilityLabel("Delete lookup \(item.query)")
            remove.setAccessibilityIdentifier("dictionary.history.delete.\(item.id.uuidString)")
            remove.setAccessibilityHelp("Delete this recent lookup.")
            remove.toolTip = "Delete this lookup"

            rowIDs[index] = item.id
            row.addSubview(metadata)
            row.addSubview(query)
            row.addSubview(remove)
            listDocument.addSubview(row)
        }
    }

    @objc private func selectPressed(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect(items[sender.tag])
    }

    @objc private func deletePressed(_ sender: NSButton) {
        guard let id = rowIDs[sender.tag] else { return }
        onDelete(id)
    }

    @objc private func clearPressed(_ sender: NSButton) {
        let hasError = !(errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !items.isEmpty || hasError else { return }
        guard isConfirmingClear else {
            isConfirmingClear = true
            clearButton.title = "Clear all?"
            clearButton.setAccessibilityHelp("Press again to remove every recent lookup, or choose Cancel.")
            cancelClearButton.isHidden = false
            return
        }
        isConfirmingClear = false
        cancelClearButton.isHidden = true
        clearButton.title = "Clear"
        onClear()
    }

    @objc private func cancelClearPressed(_ sender: NSButton) {
        isConfirmingClear = false
        cancelClearButton.isHidden = true
        clearButton.title = "Clear"
        clearButton.setAccessibilityHelp("Remove all recent dictionary lookups.")
    }

    private static func displayQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func metadata(for item: DictionaryPanelHistoryItem) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(item.lookedUpAt) {
            formatter.timeStyle = .short
        } else if calendar.component(.year, from: item.lookedUpAt) == calendar.component(.year, from: Date()) {
            formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        }
        let source = item.sourceLanguage.isAutomatic ? (item.detectedSourceLanguage ?? .automatic) : item.sourceLanguage
        let mode = item.presentationMode == .translate ? "Translate · " : ""
        return "\(mode)\(source.shortDisplayName.uppercased()) → \(item.targetLanguage.rawValue.uppercased()) · \(formatter.string(from: item.lookedUpAt))"
    }

    private static func fullMetadata(for item: DictionaryPanelHistoryItem) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let source = item.sourceLanguage.isAutomatic ? (item.detectedSourceLanguage ?? .automatic) : item.sourceLanguage
        let mode = item.presentationMode == .translate ? "Translate" : "Dictionary"
        return "\(mode) · \(source.displayName) → \(item.targetLanguage.displayName) · \(formatter.string(from: item.lookedUpAt))"
    }

}

// MARK: - Dictionary panel controller

@MainActor
public final class DictionaryPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let presentationMode: DictionaryPanelPresentationMode
    private let placementClock: () -> TimeInterval
    private let screenGeometryProvider: () -> [DictionaryPanelScreenGeometry]
    private let pointerLocationProvider: () -> NSPoint
    private let usesSyntheticPlacementGeometry: Bool
    private let panel: DictionaryPanelWindow
    private let background: DictionaryPanelSurfaceView
    private let headerTitle: NSTextField
    private let modeButton: NSButton
    private let sourcePopup: NSPopUpButton
    private let historyButton: NSButton
    private let targetPopup: NSPopUpButton
    private let languageArrow = NSTextField(labelWithString: "→")
    private let closeButton: NSButton
    private let searchSurface: DictionarySearchSurface
    private var isSearchHovered = false
    private var searchExpansion: CGFloat = 1
    private var searchAnimationTarget: CGFloat?
    private var searchAnimationTask: Task<Void, Never>?
    private let translationSourceEditor = NSTextView()
    private var translationSourceDraft: String?
    private var sourceEditTask: Task<Void, Never>?
    private let lookupField: NSTextField
    private let lookupButton: NSButton
    private let clearButton: NSButton
    private let scrollView: NSScrollView
    private let bodyDocument: DictionaryPanelSurfaceView
    private let progressIndicator: NSProgressIndicator

    private var state: DictionaryPanelViewState = .empty
    private var historyPopover: NSPopover?
    private weak var historyPopoverController: DictionaryHistoryPopoverController?
    private var submitHandler: ((String) -> Void)?
    private var selectTokenHandler: ((DictionaryPanelToken) -> Void)?
    private var targetChangeHandler: ((DictionaryTargetLanguage) -> Void)?
    private var sourceChangeHandler: ((DictionarySourceLanguage) -> Void)?
    private var speakHandler: ((DictionarySpeechRequest) -> Void)?
    private var retryHandler: (() -> Void)?
    private var toggleModeHandler: ((String) -> Void)?
    private var dismissHandler: (() -> Void)?
    private var permissionSettingsHandler: (() -> Void)?
    private var historySelectHandler: ((DictionaryPanelHistoryItem) -> Void)?
    private var historyDeleteHandler: ((UUID) -> Void)?
    private var historyClearHandler: (() -> Void)?
    private var historyItems: [DictionaryPanelHistoryItem] = []
    private var historyError: String?
    private lazy var clickAwayDismissal = TransientPanelDismissal(
        window: panel,
        relatedWindows: { [weak self] in
            self?.historyPopover?.contentViewController?.view.window.map { [$0] } ?? []
        },
        onDismiss: { [weak self] in self?.dismissFromUser() }
    )
    private var isDismissing = false
    private var lastRenderedQuery: String?
    private var hasEditedLookupDraft = false
    private var lastRenderedBodyQuery: String?
    private var lastRenderedBodyPresentationMode: DictionaryPresentationMode?
    private var lastSizedQuery: String?
    private var lastSizedPresentationMode: DictionaryPresentationMode?
    private var lastAutomaticPanelSize: NSSize?
    private var isUserSizedForQuery = false
    private var essentialContentHeight: CGFloat?
    private var isSentenceExpanded = false
    private var expandedContextKeys: Set<String> = []
    private var expandedExampleKeys: Set<String> = []
    private var expandedEntryKeys: Set<String> = []
    private var needsContentSettlement = false
    private var isResizingPanel = false
    private var isUpdatingLookupField = false
    private var programmaticFrameChangeDepth = 0
    private var isUserWindowDragInProgress = false
    private var placementSession = DictionaryPanelPlacementSession()
    private var attributionURLsByTag: [Int: URL] = [:]
    private var expandedMeaningKeys: Set<String> = []
    private var meaningDisclosureQuery: String?
    private var activeMeaningKey: String { "\(state.sentence?.activeTokenIndex ?? -1):\(state.word?.headword ?? "")" }

    public var isVisible: Bool {
        panel.isVisible
    }

    public var isKeyWindow: Bool {
        panel.isKeyWindow
    }

    var currentDraft: String {
        let visibleDraft = (lookupField.currentEditor() as? NSTextView)?.string ?? lookupField.stringValue
        if let translationSourceDraft,
           visibleDraft == Self.lookupDisplayText(translationSourceDraft) { return translationSourceDraft }
        // The field is one line, while selections can contain whole paragraphs.
        // Keep their original source until the user actually edits the draft.
        if !hasEditedLookupDraft, lastRenderedQuery == state.query,
           visibleDraft == Self.lookupDisplayText(state.query) {
            return state.query
        }
        return visibleDraft
    }

    /// Explicit lookup operations replace unfinished typing even when they
    /// restore the same query. Routine asynchronous updates retain the draft.
    func prepareForNewLookup() {
        sourceEditTask?.cancel()
        sourceEditTask = nil
        translationSourceDraft = nil
        isSearchHovered = false
        if isLookupEditing { panel.makeFirstResponder(nil) }
        cancelSearchAnimation()
        lastRenderedQuery = nil
        hasEditedLookupDraft = false
    }

    private var isLookupEditing: Bool {
        panel.firstResponder === lookupField
            || (lookupField.currentEditor().map { panel.firstResponder === $0 } ?? false)
    }

    private var isSearchCollapsed: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSearchHovered && !isLookupEditing
            && (state.presentationMode == .translate || state.mode != .manual)
    }

    func setSearchHovered(_ hovered: Bool, animated: Bool = false) {
        guard isSearchHovered != hovered else { return }
        isSearchHovered = hovered
        transitionSearchPresentation(animated: animated)
    }

    private func transitionSearchPresentation(animated: Bool) {
        let target: CGFloat = isSearchCollapsed ? 0 : 1
        cancelSearchAnimation()
        let start = searchExpansion
        guard animated, panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(target - start) > 0.001 else {
            searchExpansion = target
            layoutFramesForPanelSize()
            return
        }
        searchAnimationTarget = target
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = ShortcutUIStyle.controlTransitionDuration * Double(abs(target - start))
        // Move the existing viewport and fade its controls. Rebuilding the
        // body during hover would discard the source editor's cursor/undo.
        searchAnimationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let fraction = min(1, elapsed / duration)
                let eased = CGFloat(fraction * fraction * (3 - 2 * fraction))
                self.searchExpansion = start + (target - start) * eased
                self.layoutFramesForPanelSize()
                if fraction >= 1 {
                    self.searchAnimationTarget = nil
                    self.searchAnimationTask = nil
                    return
                }
                do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
            }
        }
    }

    private func cancelSearchAnimation() {
        searchAnimationTask?.cancel()
        searchAnimationTask = nil
        searchAnimationTarget = nil
    }

    public override convenience init() {
        self.init(presentationMode: .active)
    }

    public convenience init(presentationMode: DictionaryPanelPresentationMode) {
        self.init(
            presentationMode: presentationMode,
            placementClock: { ProcessInfo.processInfo.systemUptime },
            screenGeometryProvider: {
                NSScreen.screens.map { DictionaryPanelScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            },
            pointerLocationProvider: { NSEvent.mouseLocation },
            usesSyntheticPlacementGeometry: false
        )
    }

    init(
        presentationMode: DictionaryPanelPresentationMode,
        placementClock: @escaping () -> TimeInterval,
        screenGeometryProvider: @escaping () -> [DictionaryPanelScreenGeometry],
        pointerLocationProvider: @escaping () -> NSPoint,
        usesSyntheticPlacementGeometry: Bool
    ) {
        self.presentationMode = presentationMode
        self.placementClock = placementClock
        self.screenGeometryProvider = screenGeometryProvider
        self.pointerLocationProvider = pointerLocationProvider
        self.usesSyntheticPlacementGeometry = usesSyntheticPlacementGeometry
        panel = DictionaryPanelWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DictionaryPanelLayout.panelWidth,
                height: DictionaryPanelLayout.panelHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        background = DictionaryPanelSurfaceView(frame: NSRect(
            x: 0,
            y: 0,
            width: DictionaryPanelLayout.panelWidth,
            height: DictionaryPanelLayout.panelHeight
        ))
        headerTitle = NSTextField(labelWithString: "Dictionary")
        modeButton = DictionaryHoverButton(frame: .zero)
        sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        historyButton = DictionaryHoverButton(frame: .zero)
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        closeButton = DictionaryHoverButton(frame: .zero)
        searchSurface = DictionarySearchSurface(frame: .zero)
        lookupField = NSTextField(frame: .zero)
        lookupButton = DictionaryHoverButton(frame: .zero)
        clearButton = DictionaryHoverButton(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        bodyDocument = DictionaryPanelSurfaceView(frame: .zero)
        progressIndicator = NSProgressIndicator(frame: .zero)
        super.init()

        panel.owner = self
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Dictionary")

        configureBackground()
        configureHeader()
        configureSearch()
        configureScrollView()
        panel.contentView = background
    }

    // MARK: Lifecycle and callbacks

    public func show(
        state: DictionaryPanelViewState,
        onSubmit: @escaping (String) -> Void,
        onSelectToken: @escaping (DictionaryPanelToken) -> Void = { _ in },
        onTargetChange: @escaping (DictionaryTargetLanguage) -> Void = { _ in },
        onSourceChange: @escaping (DictionarySourceLanguage) -> Void = { _ in },
        onSpeak: @escaping (DictionarySpeechRequest) -> Void = { _ in },
        onRetry: @escaping () -> Void = {},
        onToggleMode: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
        onOpenPermissionSettings: @escaping () -> Void = {},
        history: [DictionaryPanelHistoryItem] = [],
        historyError: String? = nil,
        onHistorySelect: @escaping (DictionaryPanelHistoryItem) -> Void = { _ in },
        onHistoryDelete: @escaping (UUID) -> Void = { _ in },
        onHistoryClear: @escaping () -> Void = {}
    ) {
        beginPlacementOperation()
        cancelSearchAnimation()
        self.state = state
        historyItems = history
        self.historyError = historyError
        lastRenderedQuery = nil
        lastRenderedBodyQuery = nil
        lastRenderedBodyPresentationMode = nil
        submitHandler = onSubmit
        selectTokenHandler = onSelectToken
        targetChangeHandler = onTargetChange
        sourceChangeHandler = onSourceChange
        speakHandler = onSpeak
        retryHandler = onRetry
        toggleModeHandler = onToggleMode
        dismissHandler = onDismiss
        permissionSettingsHandler = onOpenPermissionSettings
        historySelectHandler = onHistorySelect
        historyDeleteHandler = onHistoryDelete
        historyClearHandler = onHistoryClear
        isDismissing = false
        lastSizedQuery = nil
        lastSizedPresentationMode = nil
        lastAutomaticPanelSize = nil
        isUserSizedForQuery = false
        needsContentSettlement = false

        updateInterface()
        switch presentationMode {
        case .active:
            applyCurrentPlacement()
        case .offscreenTest:
            if usesSyntheticPlacementGeometry {
                applyCurrentPlacement()
            } else if !placementSession.isUserMoved {
                withProgrammaticFrameChange {
                    panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                }
            }
        }
        bringForward()
        if (state.presentationMode == .dictionary && state.mode == .manual) || state.query.isEmpty {
            panel.makeFirstResponder(lookupField)
        }
        updateSurfaceFocus()
    }

    public func update(state: DictionaryPanelViewState) {
        let beginsLookup = state.query != self.state.query
        let changesMode = state.presentationMode != self.state.presentationMode
        if beginsLookup {
            beginPlacementOperation()
        }
        self.state = state
        updateInterface()
        if beginsLookup {
            applyCurrentPlacement()
        }
        if (beginsLookup || changesMode), state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.makeFirstResponder(lookupField)
            updateSurfaceFocus()
        }
    }

    /// Refreshes the local history list without rebuilding the current result
    /// or changing the sentence scroll position.
    public func updateHistory(
        _ items: [DictionaryPanelHistoryItem],
        errorMessage: String? = nil
    ) {
        historyItems = items
        historyError = errorMessage
        historyPopoverController?.update(items: items, errorMessage: errorMessage)
    }

    /// Builds the history surface without presenting an NSPopover. Native UI
    /// fixtures use this to render and exercise the history actions in an
    /// offscreen window, so those checks never activate or flash the desktop.
    internal func makeHistoryViewControllerForOffscreenFixture() -> NSViewController {
        let result = DictionaryHistoryPopoverController(
            items: historyItems,
            errorMessage: historyError,
            onSelect: { [weak self] item in
                self?.beginPlacementOperation()
                self?.historySelectHandler?(item)
            },
            onDelete: { [weak self] id in
                guard let self else { return }
                self.recordHumanActivity()
                self.historyItems.removeAll { $0.id == id }
                self.historyError = nil
                self.historyPopoverController?.update(items: self.historyItems, errorMessage: nil)
                self.historyDeleteHandler?(id)
            },
            onClear: { [weak self] in
                guard let self else { return }
                self.recordHumanActivity()
                self.historyItems.removeAll()
                self.historyError = nil
                self.historyPopoverController?.update(items: [], errorMessage: nil)
                self.historyClearHandler?()
            }
        )
        historyPopoverController = result
        return result
    }

    public func dismiss() {
        dismissFromUser()
    }

    /// Brings the existing Dictionary panel forward without rebuilding its
    /// view state or changing the current draft/scroll. An expired moved
    /// placement session is centered before the panel is activated.
    /// Active panels order their window before activating the application;
    /// offscreen fixtures only order their window front.
    public func bringForward() {
        beginPlacementOperation()
        applyCurrentPlacement()
        switch presentationMode {
        case .active:
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            clickAwayDismissal.start()
        case .offscreenTest:
            panel.orderFront(nil)
        }
    }

    public func releaseResources() {
        cancelSearchAnimation()
        sourceEditTask?.cancel()
        clickAwayDismissal.stop()
        historyPopover?.close()
        historyPopover = nil
        historyPopoverController = nil
        historyError = nil
        panel.orderOut(nil)
        submitHandler = nil
        selectTokenHandler = nil
        targetChangeHandler = nil
        sourceChangeHandler = nil
        speakHandler = nil
        retryHandler = nil
        toggleModeHandler = nil
        dismissHandler = nil
        permissionSettingsHandler = nil
        historySelectHandler = nil
        historyDeleteHandler = nil
        historyClearHandler = nil
        placementSession.reset()
        isUserWindowDragInProgress = false
    }

    fileprivate func cancelFromUser() {
        dismissFromUser()
    }

    func handlePanelKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modeModifiers: NSEvent.ModifierFlags = [.shift, .option, .control, .command]
        if event.keyCode == 48, flags.intersection(modeModifiers).isEmpty {
            if (lookupField.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
            if translationSourceEditor.hasMarkedText() { return false }
            if !event.isARepeat { toggleModeHandler?(currentDraft) }
            return true
        }
        if event.keyCode == 37, flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            setSearchHovered(true)
            panel.makeFirstResponder(lookupField)
            return true
        }
        guard flags.contains(.option),
              !flags.contains(.command),
              !flags.contains(.control),
              state.sentence != nil
        else { return false }

        // Keep Option-Left/Right available for normal text editing. The panel
        // only consumes them after the lookup field has handed back focus.
        if panel.firstResponder === lookupField
            || (lookupField.currentEditor().map { panel.firstResponder === $0 } ?? false)
        {
            return false
        }

        switch event.keyCode {
        case 123: // Left arrow
            selectAdjacentToken(delta: -1)
            return true
        case 124: // Right arrow
            selectAdjacentToken(delta: 1)
            return true
        default:
            return false
        }
    }

    public func windowWillMove(_ notification: Notification) {
        guard programmaticFrameChangeDepth == 0 else { return }
        isUserWindowDragInProgress = true
        recordHumanActivity()
    }

    public func windowDidMove(_ notification: Notification) {
        guard programmaticFrameChangeDepth == 0, isUserWindowDragInProgress else { return }
        let screen = screenGeometry(containing: panel.frame)
        placementSession.recordUserMove(at: placementClock(), screenFrame: screen?.frame)
    }

    fileprivate func recordPanelInput(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            recordHumanActivity()
        default:
            break
        }
    }

    func finishPanelWindowDrag() {
        isUserWindowDragInProgress = false
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissFromUser()
        return false
    }

    // MARK: NSTextFieldDelegate

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === lookupField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitLookup()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissFromUser()
            return true
        }
        return false
    }

    public func controlTextDidBeginEditing(_ notification: Notification) {
        transitionSearchPresentation(animated: false)
        updateSurfaceFocus()
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        transitionSearchPresentation(animated: true)
        updateSurfaceFocus()
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingLookupField else { return }
        hasEditedLookupDraft = true
        if state.presentationMode == .translate {
            sourceEditTask?.cancel()
            translationSourceDraft = (lookupField.currentEditor() as? NSTextView)?.string ?? lookupField.stringValue
            translationSourceEditor.string = translationSourceDraft ?? ""
        }
        recordHumanActivity()
        updateLookupButtonState()
    }

    public func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === translationSourceEditor else { return }
        translationSourceDraft = translationSourceEditor.string
        isUpdatingLookupField = true
        lookupField.stringValue = Self.lookupDisplayText(translationSourceEditor.string)
        isUpdatingLookupField = false
        hasEditedLookupDraft = true
        recordHumanActivity()
        updateLookupButtonState()
        sourceEditTask?.cancel()
        guard !translationSourceEditor.hasMarkedText() else { return }
        let draft = translationSourceEditor.string
        sourceEditTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, self.panel.isVisible, self.state.presentationMode == .translate,
                  self.translationSourceEditor.string == draft,
                  !self.translationSourceEditor.hasMarkedText() else { return }
            self.submitLookup()
        }
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === translationSourceEditor else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           !NSEvent.modifierFlags.contains(.shift) {
            submitLookup()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissFromUser()
            return true
        }
        return false
    }

    // MARK: Static controls

    private func configureBackground() {
        background.autoresizingMask = [.width, .height]
        ShortcutUIStyle.configurePanelSurface(
            background,
            cornerRadius: ShortcutUIStyle.explainCornerRadius
        )
    }

    private func configureHeader() {
        headerTitle.cell = DictionaryCenteredTextFieldCell(textCell: "Dictionary")
        headerTitle.isEditable = false
        headerTitle.isSelectable = false
        headerTitle.isBordered = false
        headerTitle.isBezeled = false
        headerTitle.drawsBackground = false
        headerTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        headerTitle.textColor = ShortcutUIStyle.primaryTextColor
        headerTitle.frame = NSRect(
            x: DictionaryPanelLayout.headerInset,
            y: DictionaryPanelLayout.headerY,
            width: 190,
            height: DictionaryPanelLayout.headerControlHeight
        )
        headerTitle.setAccessibilityLabel("Dictionary")
        headerTitle.setAccessibilityIdentifier("dictionary.header")

        modeButton.isBordered = false
        modeButton.focusRingType = .default
        modeButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Switch Dictionary mode")?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        modeButton.imagePosition = .imageOnly
        modeButton.contentTintColor = DictionaryPanelStyle.accentTextColor
        modeButton.wantsLayer = true
        modeButton.layer?.cornerRadius = 8
        (modeButton as? DictionaryHoverButton)?.configureHover(
            normal: ShortcutUIStyle.accentColor.withAlphaComponent(0.08),
            hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.20)
        )
        modeButton.target = self
        modeButton.action = #selector(toggleModePressed(_:))
        modeButton.frame = NSRect(x: 138, y: DictionaryPanelLayout.headerY, width: 32, height: 32)
        modeButton.setAccessibilityIdentifier("dictionary.mode.toggle")

        sourcePopup.cell = DictionaryLanguagePopupCell(textCell: "", pullsDown: false)
        sourcePopup.isBordered = false
        sourcePopup.removeAllItems()
        for source in DictionarySourceLanguage.allCases {
            sourcePopup.addItem(withTitle: source.displayName)
            sourcePopup.lastItem?.representedObject = source.rawValue
        }
        sourcePopup.font = .systemFont(ofSize: 12.5, weight: .medium)
        sourcePopup.alignment = .right
        sourcePopup.appearance = NSAppearance(named: .darkAqua)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        sourcePopup.setAccessibilityLabel("Source language")
        sourcePopup.setAccessibilityIdentifier("dictionary.source")
        sourcePopup.setAccessibilityHelp("Choose a source language or keep automatic detection.")
        sourcePopup.toolTip = "Choose source language · Auto keeps detection"
        sourcePopup.frame = NSRect(x: 389, y: 14, width: 117, height: 28)

        historyButton.isBordered = false
        historyButton.focusRingType = .default
        historyButton.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "Dictionary history"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        historyButton.imagePosition = .imageOnly
        historyButton.contentTintColor = ShortcutUIStyle.primaryTextColor
        (historyButton as? DictionaryHoverButton)?.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.primaryTextColor.withAlphaComponent(0.10)
        )
        historyButton.target = self
        historyButton.action = #selector(showHistoryPopover(_:))
        historyButton.frame = NSRect(x: 478, y: 12, width: 32, height: 32)
        historyButton.setAccessibilityLabel("Dictionary history")
        historyButton.setAccessibilityIdentifier("dictionary.history")
        historyButton.setAccessibilityHelp("View and reopen recent dictionary lookups.")
        historyButton.toolTip = "Recent dictionary lookups"

        targetPopup.cell = DictionaryLanguagePopupCell(textCell: "", pullsDown: false)
        targetPopup.isBordered = false
        targetPopup.menu?.autoenablesItems = false
        targetPopup.font = sourcePopup.font
        targetPopup.appearance = sourcePopup.appearance
        for target in DictionaryTargetLanguage.allCases {
            targetPopup.addItem(withTitle: target.displayName)
            targetPopup.lastItem?.representedObject = target.rawValue
        }
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged(_:))
        targetPopup.setAccessibilityLabel("Target language")
        targetPopup.setAccessibilityIdentifier("dictionary.target")
        targetPopup.toolTip = "Choose translation language"
        languageArrow.font = .systemFont(ofSize: 13)
        languageArrow.textColor = ShortcutUIStyle.secondaryTextColor
        languageArrow.alignment = .center
        languageArrow.setAccessibilityElement(false)

        closeButton.isBordered = false
        closeButton.focusRingType = .default
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Dictionary"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        (closeButton as? DictionaryHoverButton)?.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.12)
        )
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.frame = NSRect(x: 558, y: 12, width: 32, height: 32)
        closeButton.setAccessibilityLabel("Close Dictionary")
        closeButton.setAccessibilityHelp("Closes the Dictionary panel.")
        closeButton.toolTip = "Close Dictionary · Escape"

        background.addSubview(headerTitle)
        background.addSubview(modeButton)
        background.addSubview(sourcePopup)
        background.addSubview(historyButton)
        background.addSubview(languageArrow)
        background.addSubview(targetPopup)
        background.addSubview(closeButton)
    }

    private func configureSearch() {
        searchSurface.onHover = { [weak self] hovered in self?.setSearchHovered(hovered, animated: true) }
        searchSurface.frame = NSRect(
            x: DictionaryPanelLayout.searchInset,
            y: DictionaryPanelLayout.searchY,
            width: DictionaryPanelLayout.panelWidth - DictionaryPanelLayout.searchInset * 2,
            height: DictionaryPanelLayout.searchHeight
        )
        ShortcutUIStyle.configureContentSurface(
            searchSurface,
            cornerRadius: ShortcutUIStyle.inputCornerRadius
        )
        searchSurface.layer?.borderColor = DictionaryPanelStyle.focusBorderColor.cgColor
        searchSurface.layer?.masksToBounds = true
        searchSurface.setAccessibilityIdentifier("dictionary.lookup.surface")

        lookupField.cell = DictionaryCenteredTextFieldCell(textCell: "")
        lookupField.delegate = self
        lookupField.isEditable = true
        lookupField.isSelectable = true
        lookupField.isBezeled = false
        lookupField.drawsBackground = false
        lookupField.focusRingType = .none
        lookupField.font = .systemFont(ofSize: 16, weight: .regular)
        lookupField.textColor = ShortcutUIStyle.primaryTextColor
        lookupField.placeholderAttributedString = NSAttributedString(
            string: "Type a word or sentence…",
            attributes: [.foregroundColor: DictionaryPanelStyle.placeholderTextColor]
        )
        lookupField.frame = NSRect(
            x: DictionaryPanelLayout.lookupFieldInset,
            y: 8,
            width: searchSurface.bounds.width - 104,
            height: 36
        )
        lookupField.maximumNumberOfLines = 1
        lookupField.lineBreakMode = .byTruncatingTail
        lookupField.cell?.usesSingleLineMode = true
        lookupField.setAccessibilityLabel("Dictionary lookup")
        lookupField.setAccessibilityIdentifier("dictionary.lookup")
        lookupField.setAccessibilityHelp("Enter a word or sentence. Press Return to look it up or Escape to close the panel.")
        lookupField.toolTip = "Return to look up · Escape to close"

        lookupButton.isBordered = false
        lookupButton.focusRingType = .default
        lookupButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Look up"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        lookupButton.imagePosition = .imageOnly
        lookupButton.contentTintColor = DictionaryPanelStyle.accentTextColor
        lookupButton.wantsLayer = true
        lookupButton.layer?.cornerRadius = 8
        (lookupButton as? DictionaryHoverButton)?.configureHover(
            normal: ShortcutUIStyle.accentColor.withAlphaComponent(0.12),
            hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.24)
        )
        lookupButton.target = self
        lookupButton.action = #selector(submitLookupButton(_:))
        lookupButton.frame = NSRect(
            x: searchSurface.bounds.width
                - DictionaryPanelLayout.lookupTrailingInset
                - DictionaryPanelLayout.lookupClearWidth
                - DictionaryPanelLayout.controlGap
                - DictionaryPanelLayout.lookupButtonWidth,
            y: 10,
            width: DictionaryPanelLayout.lookupButtonWidth,
            height: 32
        )
        lookupButton.setAccessibilityLabel("Look up")
        lookupButton.setAccessibilityIdentifier("dictionary.lookup.submit")
        lookupButton.setAccessibilityHelp("Look up the text in the field. Press Return for the same action.")
        lookupButton.toolTip = "Look up · Return"
        lookupButton.isEnabled = false

        clearButton.isBordered = false
        clearButton.focusRingType = .default
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear lookup"
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = ShortcutUIStyle.secondaryTextColor
        (clearButton as? DictionaryHoverButton)?.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.12)
        )
        clearButton.target = self
        clearButton.action = #selector(clearLookup(_:))
        clearButton.frame = NSRect(
            x: searchSurface.bounds.width
                - DictionaryPanelLayout.lookupTrailingInset
                - DictionaryPanelLayout.lookupClearWidth,
            y: 10,
            width: DictionaryPanelLayout.lookupClearWidth,
            height: 30
        )
        clearButton.setAccessibilityLabel("Clear lookup")
        clearButton.setAccessibilityIdentifier("dictionary.lookup.clear")
        clearButton.setAccessibilityHelp("Clear the lookup and return to manual input.")
        clearButton.toolTip = "Clear lookup"

        searchSurface.addSubview(lookupField)
        searchSurface.addSubview(lookupButton)
        searchSurface.addSubview(clearButton)
        background.addSubview(searchSurface)
    }

    private func configureScrollView() {
        scrollView.frame = NSRect(
            x: DictionaryPanelLayout.outerInset,
            y: DictionaryPanelLayout.scrollY,
            width: DictionaryPanelLayout.panelWidth - DictionaryPanelLayout.outerInset * 2,
            height: DictionaryPanelLayout.panelHeight - DictionaryPanelLayout.scrollY - DictionaryPanelLayout.outerInset
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        // Legacy scrollers consume viewport width. Keeping them present avoids
        // a width jump when the user first scrolls; overlay scrollers always
        // use the same reserved body gutter, whether visible or not.
        scrollView.autohidesScrollers = scrollView.scrollerStyle == .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 14
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor
        bodyDocument.frame = NSRect(x: 0, y: 0, width: 570, height: 470)
        scrollView.documentView = bodyDocument
        background.addSubview(scrollView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Dictionary loading")
        progressIndicator.setAccessibilityIdentifier("dictionary.status.loading")
    }

    private func updateInterface() {
        // Async dictionary and AI updates can arrive while the user is
        // editing a new draft. Only replace the field when the model query
        // itself changed; preserve an in-progress draft for same-query
        // updates.
        if lastRenderedQuery == nil || lastRenderedQuery != state.query {
            translationSourceDraft = nil
            isUpdatingLookupField = true
            lookupField.stringValue = Self.lookupDisplayText(state.query)
            lastRenderedQuery = state.query
            hasEditedLookupDraft = false
            if let editor = lookupField.currentEditor() as? NSTextView {
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
            isUpdatingLookupField = false
        }
        updateLookupButtonState()
        let translating = state.presentationMode == .translate
        headerTitle.stringValue = translating ? "Translate" : "Dictionary"
        headerTitle.setAccessibilityLabel(translating ? "Translate" : "Dictionary")
        let nextMode = translating ? "Dictionary" : "Translate"
        modeButton.setAccessibilityLabel("Switch to \(nextMode)")
        modeButton.setAccessibilityHelp("Switch to \(nextMode). Press Tab for the same action; Shift-Tab moves focus.")
        modeButton.toolTip = "Switch to \(nextMode) · Tab"
        lookupButton.setAccessibilityLabel(translating ? "Translate" : "Look up")
        lookupButton.toolTip = translating ? "Translate · Return" : "Look up · Return"
        lookupField.setAccessibilityHelp("Enter text. Press Return to \(translating ? "translate" : "look it up"), Tab to switch mode, or Escape to close.")
        lookupField.toolTip = "Return to \(translating ? "translate" : "look up") · Escape to close"
        if !sourcePopup.itemArray.contains(where: { ($0.representedObject as? String) == state.sourceLanguage.rawValue }) {
            sourcePopup.addItem(withTitle: state.sourceLanguage.displayName)
            sourcePopup.lastItem?.representedObject = state.sourceLanguage.rawValue
        }
        if let index = sourcePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == state.sourceLanguage.rawValue
        }) {
            sourcePopup.selectItem(at: index)
        }
        targetPopup.selectItem(withTitle: state.targetLanguage.displayName)
        updateLanguageChoices()
        layoutFramesForPanelSize()
        updateSurfaceFocus()
        renderBody()
    }

    private var resolvedSourceLanguage: DictionarySourceLanguage {
        if !state.sourceLanguage.isAutomatic { return state.sourceLanguage }
        guard !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .automatic }
        if let detected = state.detectedSourceLanguage, !detected.isAutomatic { return detected }
        return DictionaryLanguageService.detect(state.query, preferred: .automatic)
    }

    private func updateLanguageChoices() {
        let detected = resolvedSourceLanguage
        let detail = state.sourceLanguage.isAutomatic && !detected.isAutomatic
            ? "Auto · detected \(detected.displayName)" : state.sourceLanguage.displayName
        let automaticItem = sourcePopup.itemArray.first {
            ($0.representedObject as? String) == DictionarySourceLanguage.automatic.rawValue
        }
        automaticItem?.title = state.sourceLanguage.isAutomatic && !detected.isAutomatic
            ? "Auto · \(detected.displayName)" : "Auto"
        let compact: String
        switch detected.rawValue.lowercased() {
        case "zh", "zh-hans": compact = "简"
        case "zh-hant": compact = "繁"
        default: compact = detected.canonicalCode.uppercased()
        }
        (sourcePopup.cell as? DictionaryLanguagePopupCell)?.compactTitle =
            state.sourceLanguage.isAutomatic && !detected.isAutomatic ? "Auto · \(compact)" : nil
        sourcePopup.needsDisplay = true
        sourcePopup.toolTip = "\(detail). Choose a source language to correct detection."
        sourcePopup.setAccessibilityHelp(sourcePopup.toolTip)
        sourcePopup.setAccessibilityValue(detail)
        for item in targetPopup.itemArray {
            guard let target = item.representedObject as? String else { continue }
            item.isEnabled = state.presentationMode != .translate
                || !DictionaryTranslationLanguagePolicy.isSameLanguage(detected.rawValue, target)
        }
        targetPopup.setAccessibilityHelp(state.presentationMode == .translate
            ? "Choose a different language. Simplified and Traditional Chinese can be converted between scripts."
            : "Choose the language for definitions and examples.")
    }

    private func updateSurfaceFocus() {
        let focused = panel.firstResponder === lookupField
            || (lookupField.currentEditor().map { panel.firstResponder === $0 } ?? false)
        searchSurface.layer?.borderColor = focused
            ? DictionaryPanelStyle.focusBorderColor.cgColor
            : ShortcutUIStyle.contentBorderColor.cgColor
    }

    private func updateLookupButtonState() {
        let hasQuery = !currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lookupButton.isEnabled = hasQuery
        lookupButton.alphaValue = (hasQuery ? 1 : 0.56) * searchExpansion
    }

    /// The clip view already excludes a legacy scroller. Overlay scrollers
    /// paint inside it, so reserve their native width plus one consistent gap;
    /// the result is the same usable text width in both modes.
    private var bodyRendererWidth: CGFloat {
        let viewportWidth = scrollView.contentView.bounds.width
        let overlayStrip = scrollView.scrollerStyle == .overlay
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
            : 0
        return max(1, viewportWidth - overlayStrip - DictionaryPanelLayout.bodyScrollerGap)
    }

    private func renderBody(preserveDocumentHeight: Bool = true) {
        let sourceWasFocused = panel.firstResponder === translationSourceEditor
        let sourceSelection = translationSourceEditor.selectedRange()
        if lastSizedQuery == state.query, let automaticSize = lastAutomaticPanelSize,
           panel.frame.size != automaticSize {
            isUserSizedForQuery = true
        }
        fitPanelToState()
        essentialContentHeight = nil
        let shouldPreserveScroll = lastRenderedBodyQuery == state.query
            && lastRenderedBodyPresentationMode == state.presentationMode
        let preservedScrollOrigin = shouldPreserveScroll
            ? scrollView.contentView.bounds.origin
            : .zero
        let previousDocumentHeight = bodyDocument.frame.height
        let shouldPreserveDocumentHeight = preserveDocumentHeight && shouldPreserveScroll
        for view in bodyDocument.subviews {
            view.removeFromSuperview()
        }

        if meaningDisclosureQuery != state.query {
            expandedMeaningKeys.removeAll()
            expandedExampleKeys.removeAll()
            expandedEntryKeys.removeAll()
            expandedContextKeys.removeAll()
            isSentenceExpanded = false
            meaningDisclosureQuery = state.query
        }
        let width = bodyRendererWidth
        bodyDocument.setFrameSize(NSSize(
            width: scrollView.contentView.bounds.width,
            height: bodyDocument.frame.height
        ))

        if state.isLoading {
            lookupButton.image = nil
            progressIndicator.frame = lookupButton.frame.insetBy(dx: 7, dy: 7)
            searchSurface.addSubview(progressIndicator)
            progressIndicator.startAnimation(nil)
            progressIndicator.isHidden = isSearchCollapsed
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.removeFromSuperview()
            lookupButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Look up")?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        }
        var y = DictionaryPanelLayout.contentInset

        if state.presentationMode == .translate {
            y = renderTranslation(at: y, width: width)
        } else if let sentence = state.sentence {
            y = renderSentence(sentence, at: y, width: width)
            let token = sentence.tokens.indices.contains(sentence.activeTokenIndex) ? sentence.tokens[sentence.activeTokenIndex] : nil
            if let word = state.word ?? token.map({ DictionaryPanelWord(originalText: $0.text, headword: $0.headword ?? $0.text) }) {
                y += DictionaryPanelLayout.sectionGap - 2
                y = renderWord(word, at: y, width: width)
            }
        } else if let word = state.word {
            y = renderWord(word, at: y, width: width)
        } else if state.mode == .manual || state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            y = renderManualHint(at: y, width: width)
        } else if !state.isLoading && state.errorMessage == nil {
            y = renderManualHint(at: y, width: width, message: "No entry yet. Try another word or sentence.")
        }

        if state.presentationMode == .dictionary, state.word == nil, !state.aiAdditions.isEmpty {
            y = renderAIAdditions(state.aiAdditions, at: y + 8, width: width)
        }
        if let error = state.errorMessage, !error.isEmpty {
            y = renderError(error, at: y + 12, width: width)
        }

        if state.presentationMode == .dictionary, let attribution = attributionText {
            y += 14
            y = renderAttribution(attribution, at: y, width: width)
        }

        let minimumHeight = shouldPreserveDocumentHeight
            ? max(previousDocumentHeight, scrollView.contentView.bounds.height)
            : scrollView.contentView.bounds.height
        let height = max(y + DictionaryPanelLayout.contentInset, minimumHeight)
        bodyDocument.setFrameSize(NSSize(
            width: scrollView.contentView.bounds.width,
            height: height
        ))
        lastRenderedBodyQuery = state.query
        lastRenderedBodyPresentationMode = state.presentationMode
        bodyDocument.needsLayout = true
        let maximumY = max(0, height - scrollView.contentView.bounds.height)
        let restoredOrigin = NSPoint(
            x: preservedScrollOrigin.x,
            y: min(max(0, preservedScrollOrigin.y), maximumY)
        )
        scrollView.contentView.scroll(to: restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if preserveDocumentHeight {
            settlePanelHeightIfNeeded(contentHeight: essentialContentHeight ?? y, scrollOrigin: preservedScrollOrigin)
        }
        if sourceWasFocused, state.presentationMode == .translate {
            panel.makeFirstResponder(translationSourceEditor)
            let length = (translationSourceEditor.string as NSString).length
            let location = min(sourceSelection.location, length)
            translationSourceEditor.setSelectedRange(NSRange(location: location,
                length: min(sourceSelection.length, length - location)))
        }
    }

    private func settlePanelHeightIfNeeded(contentHeight: CGFloat, scrollOrigin: NSPoint) {
        // A short native/cache result must not consume the opportunity to show
        // later examples, reading, or a larger active word. Respect a viewport
        // deliberately shortened or scrolled by the user.
        let completedTranslation = state.presentationMode == .translate && !state.isLoading
        guard (needsContentSettlement || state.word?.meanings.isEmpty == false || completedTranslation),
              !isUserSizedForQuery,
              abs(scrollOrigin.y) <= 0.5,
              !isResizingPanel
        else { return }

        let visibleFrame = visibleFrameForCurrentPanel()
        let visibleHeight = visibleFrame?.insetBy(dx: 16, dy: 16).height
            ?? DictionaryPanelLayout.panelHeight
        let bottomInset = state.presentationMode == .translate
            ? max(DictionaryPanelLayout.bodyBottomInset,
                  DictionaryPanelLayout.outerInset + DictionaryPanelLayout.contentInset)
            : DictionaryPanelLayout.bodyBottomInset
        let measuredHeight = min(
            visibleHeight,
            max(
                DictionaryPanelLayout.minimumPanelHeight,
                scrollView.frame.minY
                    + contentHeight
                    + bottomInset
            )
        )
        let desiredHeight = needsContentSettlement ? measuredHeight : max(panel.frame.height, measuredHeight)
        guard abs(panel.frame.height - desiredHeight) > 1 else {
            needsContentSettlement = false
            lastAutomaticPanelSize = panel.frame.size
            return
        }

        let previousFrame = panel.frame
        isResizingPanel = true
        withProgrammaticFrameChange {
            panel.setContentSize(NSSize(width: panel.frame.width, height: desiredHeight))
            let resizedFrame = panel.frame
            let resolved = frameForAutomaticResize(
                from: previousFrame,
                to: resizedFrame.size,
                visibleFrame: visibleFrame
            )
            panel.setFrameOrigin(resolved.origin)
            updateFramesForPanelSize()
        }
        bodyDocument.setFrameSize(NSSize(
            width: scrollView.contentView.bounds.width,
            height: max(bodyDocument.frame.height, scrollView.contentView.bounds.height)
        ))
        isResizingPanel = false
        needsContentSettlement = false
        lastAutomaticPanelSize = panel.frame.size
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var attributionText: (name: String, url: URL?)? {
        if let name = state.attributionName, !name.isEmpty {
            return (name, state.attributionURL)
        }
        if let word = state.word, let name = word.sourceName, !name.isEmpty {
            return (name, word.sourceURL)
        }
        return nil
    }

    private func renderTranslation(at y: CGFloat, width: CGFloat) -> CGFloat {
        let hasSource = !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sideBySide = width >= 500
        let gap: CGFloat = 12
        let paneWidth = sideBySide ? (width - gap) / 2 : width
        let sourceText = translationSourceDraft ?? (hasSource ? state.query : "")
        let resultText = state.paragraphTranslation
            ?? (hasSource ? "Translation will appear here." : "Ready to translate.")
        let sourceHeight = translationPaneHeight(sourceText, width: paneWidth)
        let resultHeight = translationPaneHeight(resultText, width: paneWidth)
        let pairedHeight = max(sourceHeight, resultHeight)
        addTranslationPane(
            title: "SOURCE", text: sourceText,
            at: NSRect(x: 0, y: y, width: paneWidth,
                       height: sideBySide ? pairedHeight : sourceHeight),
            identifier: "dictionary.translate.source", placeholder: !hasSource,
            canSpeak: false
        )
        let resultY = sideBySide ? y : y + sourceHeight + gap
        addTranslationPane(
            title: "TRANSLATION", text: resultText,
            at: NSRect(x: sideBySide ? paneWidth + gap : 0, y: resultY,
                       width: paneWidth, height: sideBySide ? pairedHeight : resultHeight),
            identifier: "dictionary.translate.result",
            placeholder: state.paragraphTranslation == nil,
            canSpeak: state.paragraphTranslation != nil
        )
        return sideBySide ? y + pairedHeight : resultY + resultHeight
    }

    private func translationPaneHeight(_ text: String, width: CGFloat) -> CGFloat {
        max(154, measuredLabelHeight(text, width: width - 28,
                                     font: .systemFont(ofSize: 16)) + 67)
    }

    private func addTranslationPane(
        title: String, text: String, at frame: NSRect,
        identifier: String, placeholder: Bool, canSpeak: Bool
    ) {
        let pane = DictionaryPanelSurfaceView(frame: frame)
        ShortcutUIStyle.configureContentSurface(pane, cornerRadius: ShortcutUIStyle.inputCornerRadius)
        let heading = makeLabel(title, font: .systemFont(ofSize: 12, weight: .semibold),
                                color: DictionaryPanelStyle.accentTextColor)
        heading.frame = NSRect(x: 14, y: 14, width: frame.width - 68, height: 17)
        pane.addSubview(heading)
        if title == "TRANSLATION" {
            let marker = makeLabel("AI", font: .systemFont(ofSize: 12, weight: .semibold),
                                   color: ShortcutUIStyle.secondaryTextColor)
            marker.alignment = .right
            marker.frame = NSRect(x: frame.width - (canSpeak ? 76 : 43), y: 14, width: 27, height: 17)
            pane.addSubview(marker)
        }
        if title == "SOURCE" {
            let sourceScroll = NSScrollView(frame: NSRect(x: 14, y: 44, width: frame.width - 28, height: frame.height - 58))
            sourceScroll.drawsBackground = false
            sourceScroll.hasVerticalScroller = true
            sourceScroll.autohidesScrollers = true
            translationSourceEditor.delegate = self
            translationSourceEditor.isEditable = true
            translationSourceEditor.isRichText = false
            translationSourceEditor.drawsBackground = false
            translationSourceEditor.font = .systemFont(ofSize: 16)
            translationSourceEditor.textColor = ShortcutUIStyle.primaryTextColor
            translationSourceEditor.insertionPointColor = ShortcutUIStyle.accentColor
            translationSourceEditor.textContainerInset = NSSize(width: 0, height: 0)
            translationSourceEditor.textContainer?.lineFragmentPadding = 0
            translationSourceEditor.textContainer?.widthTracksTextView = true
            translationSourceEditor.isVerticallyResizable = true
            translationSourceEditor.isHorizontallyResizable = false
            translationSourceEditor.autoresizingMask = [.width]
            if translationSourceEditor.string != text { translationSourceEditor.string = text }
            translationSourceEditor.frame.size = sourceScroll.contentSize
            translationSourceEditor.setAccessibilityLabel("Full source text")
            translationSourceEditor.setAccessibilityIdentifier(identifier)
            translationSourceEditor.setAccessibilityHelp("Edit to translate after a short pause. Return translates; Shift-Return adds a line.")
            sourceScroll.documentView = translationSourceEditor
            pane.addSubview(sourceScroll)
            bodyDocument.addSubview(pane)
            return
        }
        let content = NSTextField(wrappingLabelWithString: text)
        content.isSelectable = !placeholder
        content.font = .systemFont(ofSize: 16)
        content.textColor = placeholder ? ShortcutUIStyle.secondaryTextColor : ShortcutUIStyle.primaryTextColor
        content.backgroundColor = .clear
        content.frame = NSRect(x: 14, y: 44, width: frame.width - 28, height: frame.height - 58)
        content.setAccessibilityLabel(title == "SOURCE" ? "Full source text" : "Translated paragraph")
        content.setAccessibilityIdentifier(identifier)
        pane.addSubview(content)
        if canSpeak {
            let speak = makeSpeechButton(label: "Speak translation")
            speak.action = #selector(speakTranslation(_:))
            speak.frame = NSRect(x: frame.width - 45, y: 7, width: 30, height: 30)
            pane.addSubview(speak)
        }
        bodyDocument.addSubview(pane)
    }

    private func renderManualHint(
        at y: CGFloat,
        width: CGFloat,
        message: String = "No text captured. Type to look up."
    ) -> CGFloat {
        var cursor = y + 16
        let icon = NSImageView(frame: NSRect(x: width / 2 - 18, y: cursor, width: 36, height: 36))
        icon.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "Manual lookup")?.withSymbolConfiguration(
            .init(pointSize: 28, weight: .regular)
        )
        icon.contentTintColor = ShortcutUIStyle.secondaryTextColor
        icon.setAccessibilityLabel("Manual lookup")
        bodyDocument.addSubview(icon)
        cursor += 49

        let hint = makeLabel(message, font: .systemFont(ofSize: 13.5), color: ShortcutUIStyle.secondaryTextColor)
        hint.alignment = .center
        hint.frame = NSRect(x: 16, y: cursor, width: width - 32, height: 22)
        bodyDocument.addSubview(hint)
        cursor += 28
        let keyboard = makeLabel("Return to look up · Esc to close", font: .systemFont(ofSize: 12), color: DictionaryPanelStyle.accentTextColor)
        keyboard.alignment = .center
        keyboard.frame = NSRect(x: 0, y: cursor, width: width, height: 20)
        keyboard.setAccessibilityIdentifier("dictionary.status.keyboardHint")
        bodyDocument.addSubview(keyboard)
        cursor += 24

        guard shouldShowPermissionSettings else {
            return cursor + 10
        }

        let settings = DictionaryHoverButton(
            title: "Capture permissions & settings",
            target: self,
            action: #selector(openPermissionSettings(_:))
        )
        settings.isBordered = false
        settings.focusRingType = .default
        settings.font = .systemFont(ofSize: 12, weight: .medium)
        settings.contentTintColor = DictionaryPanelStyle.accentTextColor
        settings.configureHover(
            normal: .clear,
            hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.10)
        )
        settings.frame = NSRect(x: width / 2 - 105, y: cursor, width: 210, height: 22)
        settings.setAccessibilityLabel("Open capture permissions and settings")
        settings.setAccessibilityHelp("Open macOS Accessibility settings for selected-text capture.")
        settings.toolTip = "Open capture permissions & settings"
        bodyDocument.addSubview(settings)
        return cursor + 28
    }

    private var shouldShowPermissionSettings: Bool {
        guard let message = state.errorMessage?.lowercased() else { return false }
        return message.contains("permission")
            || message.contains("accessibility")
    }

    private func renderSentence(
        _ sentence: DictionaryPanelSentence,
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        var cursor = y
        let preserved = sentenceTokensPreservingSource(sentence)
        let sourceView = DictionarySentenceTextView(
            tokens: preserved.tokens,
            activeIndex: preserved.activeIndex,
            source: sentence.source,
            selectedRange: sentence.activeRange,
            onSelect: { [weak self] token in
                self?.beginPlacementOperation()
                self?.selectTokenHandler?(token)
            }
        )
        let sourceHeight = sourceView.requiredHeight(for: width)
        let sourcePreviewHeight = sourceView.previewHeight(maximumLines: 3)
        let compactSource = !isSentenceExpanded && sourceHeight > sourcePreviewHeight
        sourceView.frame = NSRect(x: 0, y: compactSource ? 0 : cursor, width: width, height: sourceHeight)
        if compactSource {
            let sourceScroll = NSScrollView(frame: NSRect(x: 0, y: cursor, width: width, height: sourcePreviewHeight))
            sourceScroll.drawsBackground = false
            // The full sentence has a disclosure control and the outer body
            // already scrolls. A nested scroller would obscure the same text
            // column with a second overlay strip.
            sourceScroll.hasVerticalScroller = false
            sourceScroll.autohidesScrollers = true
            sourceScroll.documentView = sourceView
            sourceScroll.setAccessibilityIdentifier("dictionary.sentence.preview")
            bodyDocument.addSubview(sourceScroll)
            sourceView.revealActiveToken()
        } else {
            bodyDocument.addSubview(sourceView)
        }
        cursor += compactSource ? sourcePreviewHeight : sourceHeight
        var hasCompactContext = sourceHeight > sourcePreviewHeight

        if let translation = sentence.translation,
           !translation.isEmpty,
           !Self.hasSameDisplayText(sentence.source, translation),
           !allKnownSourceLanguagesMatchTarget(sentence)
        {
            let translationFont = NSFont.systemFont(ofSize: 13.5)
            let translationHeight = measuredLabelHeight(translation, width: width, font: translationFont)
            let translated = makeLabel(translation, font: translationFont, color: ShortcutUIStyle.secondaryTextColor)
            let previewHeight = min(translationHeight, translationFont.boundingRectForFont.height * 3 + 4)
            hasCompactContext = hasCompactContext || translationHeight > previewHeight
            let displayedHeight = isSentenceExpanded ? translationHeight : previewHeight
            translated.frame = NSRect(x: 0, y: cursor + 8, width: width, height: displayedHeight)
            translated.maximumNumberOfLines = isSentenceExpanded ? 0 : 3
            translated.toolTip = translation
            translated.lineBreakMode = .byWordWrapping
            translated.cell?.wraps = true
            translated.setAccessibilityLabel("Sentence translation: \(translation)")
            bodyDocument.addSubview(translated)
            cursor += displayedHeight + 12
        }
        if hasCompactContext {
            let disclosure = makeDisclosure(
                title: isSentenceExpanded ? "Show less sentence context" : "Show full sentence context",
                identifier: "dictionary.sentence.disclosure", action: #selector(toggleSentenceContext(_:)),
                at: cursor, width: width
            )
            cursor = disclosure.frame.maxY + 6
        }

        let divider = NSBox(frame: NSRect(x: 0, y: cursor + 4, width: width, height: 1))
        divider.boxType = .separator
        divider.contentView?.wantsLayer = true
        divider.contentView?.layer?.backgroundColor = ShortcutUIStyle.contentBorderColor.cgColor
        bodyDocument.addSubview(divider)
        return cursor + 11
    }

    /// Contextual segmentation may return only word spans. Fill any gaps from
    /// the original sentence before rendering so punctuation, spaces, and line
    /// breaks remain visible and their UTF-16 ranges stay anchored.
    private func sentenceTokensPreservingSource(
        _ sentence: DictionaryPanelSentence
    ) -> (tokens: [DictionaryPanelToken], activeIndex: Int) {
        let source = sentence.source as NSString
        guard !sentence.tokens.isEmpty else {
            return (
                [DictionaryPanelToken(
                    text: sentence.source,
                    utf16Range: NSRange(location: 0, length: source.length),
                    isPunctuation: false,
                    isWhitespace: false
                )],
                0
            )
        }

        var result: [DictionaryPanelToken] = []
        var cursor = 0
        var displayedActive = 0
        for (index, token) in sentence.tokens.enumerated() {
            let range = token.utf16Range
            guard range.location != NSNotFound,
                  range.location >= cursor,
                  range.location <= source.length,
                  range.length >= 0,
                  range.length <= source.length - range.location
            else {
                if index == sentence.activeTokenIndex {
                    displayedActive = result.count
                }
                result.append(token)
                continue
            }

            if range.location > cursor {
                let gapRange = NSRange(location: cursor, length: range.location - cursor)
                let gap = source.substring(with: gapRange)
                result.append(Self.gapToken(gap, range: gapRange))
            }
            if index == sentence.activeTokenIndex {
                displayedActive = result.count
            }
            result.append(token)
            cursor = range.location + range.length
        }

        if cursor < source.length {
            let gapRange = NSRange(location: cursor, length: source.length - cursor)
            result.append(Self.gapToken(source.substring(with: gapRange), range: gapRange))
        }
        return (result.isEmpty ? [DictionaryPanelToken(text: sentence.source, utf16Range: NSRange(location: 0, length: source.length))] : result, displayedActive)
    }

    private static func gapToken(_ text: String, range: NSRange) -> DictionaryPanelToken {
        let isWhitespace = text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let isPunctuation = !isWhitespace && !DictionaryLanguageService.isWordContent(text)
        return DictionaryPanelToken(
            text: text,
            utf16Range: range,
            isPunctuation: isPunctuation,
            isWhitespace: isWhitespace
        )
    }

    private func renderWord(
        _ word: DictionaryPanelWord,
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        var cursor = y
        let navWidth: CGFloat = state.sentence.map { sentence in
            let text = tokenCounterText(sentence)
            let counterCell = DictionaryCenteredTextFieldCell(textCell: text)
            counterCell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            counterCell.usesSingleLineMode = true
            return 62 + max(50, ceil(counterCell.cellSize.width) + 8)
        } ?? 0
        let headingWidth = width - 40 - navWidth
        let heading = makeLabel(word.headword, font: .systemFont(ofSize: 28, weight: .semibold), color: ShortcutUIStyle.primaryTextColor)
        heading.frame = NSRect(x: 0, y: cursor, width: headingWidth, height: 36)
        heading.lineBreakMode = .byTruncatingTail
        heading.toolTip = word.headword
        heading.setAccessibilityLabel("Headword \(word.headword)")
        bodyDocument.addSubview(heading)

        if !word.originalText.isEmpty, word.originalText != word.headword {
            let original = makeLabel("(\(word.originalText))", font: .systemFont(ofSize: 12.5), color: ShortcutUIStyle.secondaryTextColor)
            let headwordWidth = ceil((word.headword as NSString).size(withAttributes: [.font: heading.font!]).width) + 8
            if headwordWidth + 60 < headingWidth {
                heading.frame.size.width = headwordWidth
                original.frame = NSRect(x: headwordWidth, y: cursor + 12, width: headingWidth - headwordWidth, height: 20)
                original.lineBreakMode = .byTruncatingTail
                original.toolTip = word.originalText
                original.setAccessibilityLabel("Original text \(word.originalText)")
                bodyDocument.addSubview(original)
            } else {
                heading.toolTip = "\(word.headword) (\(word.originalText))"
                heading.setAccessibilityHelp("Original text \(word.originalText)")
            }
        }
        let speak = makeSpeechButton(label: "Speak \(word.headword)")
        speak.tag = 0
        speak.frame = NSRect(x: width - navWidth - 32, y: cursor + 3, width: 30, height: 30)
        speak.target = self
        speak.action = #selector(speakWord(_:))
        bodyDocument.addSubview(speak)
        if let sentence = state.sentence { renderTokenNavigation(sentence, at: cursor + 3, x: width - navWidth, width: navWidth) }
        cursor += 40

        var readingParts: [String] = []
        let reading = word.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phonetic = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicateReading = reading.flatMap { reading in
            phonetic.map { Self.pronunciationKey(reading) == Self.pronunciationKey($0) }
        } ?? false
        if let reading, !reading.isEmpty, !duplicateReading {
            readingParts.append("\(reading)\(word.isAIReading ? " · AI" : "")")
        }
        if let phonetic, !phonetic.isEmpty {
            readingParts.append("IPA \(phonetic)")
        }
        if !readingParts.isEmpty {
            let text = readingParts.joined(separator: "  ·  ")
            let label = makeLabel(text, font: .systemFont(ofSize: 14), color: ShortcutUIStyle.secondaryTextColor)
            label.frame = NSRect(x: 0, y: cursor, width: width, height: measuredLabelHeight(text, width: width, font: label.font!))
            label.cell?.wraps = true
            label.setAccessibilityLabel("Pronunciation \(text)")
            label.setAccessibilityIdentifier("dictionary.pronunciation")
            bodyDocument.addSubview(label)
            cursor = label.frame.maxY + 6
        }
        if let partOfSpeech = word.partOfSpeech, !partOfSpeech.isEmpty {
            let part = makeLabel(partOfSpeech, font: .systemFont(ofSize: 12.5, weight: .semibold), color: DictionaryPanelStyle.accentTextColor)
            part.frame = NSRect(x: 0, y: cursor, width: width, height: 20)
            part.setAccessibilityLabel("Part of speech \(partOfSpeech)")
            bodyDocument.addSubview(part)
            cursor += 24
        }
        var seen: Set<String> = []
        let meanings = word.meanings.filter {
            let definition = Self.displayKey($0.definition)
            guard !definition.isEmpty else { return false }
            let translation = Self.displayKey($0.translation ?? "")
            let display = definition + (translation.isEmpty || translation == definition ? "" : "  ·  " + translation)
            return seen.insert(display).inserted
        }
        if meanings.isEmpty {
            if !state.isLoading {
                let empty = makeLabel("No structured definition available yet.", font: .systemFont(ofSize: 13.5), color: ShortcutUIStyle.secondaryTextColor)
                empty.frame = NSRect(x: 0, y: cursor, width: width, height: 22)
                bodyDocument.addSubview(empty)
                cursor += 28
            }
        } else {
            let expanded = expandedMeaningKeys.contains(activeMeaningKey)
            let defaultCount = defaultMeaningCount(meanings, word: word, at: cursor, width: width)
            for (index, meaning) in (expanded ? meanings : Array(meanings.prefix(defaultCount))).enumerated() {
                cursor = renderMeaning(meaning, number: meanings.count > 1 ? index + 1 : nil, at: cursor, width: width)
            }
            if meanings.count > defaultCount {
                let disclosure = DictionaryHoverButton(title: expanded ? "Show fewer meanings" : "Show \(meanings.count - defaultCount) more meanings", target: self, action: #selector(toggleMeanings(_:)))
                disclosure.isBordered = false
                disclosure.alignment = .left
                disclosure.font = .systemFont(ofSize: 12.5, weight: .medium)
                disclosure.contentTintColor = DictionaryPanelStyle.accentTextColor
                disclosure.configureHover(normal: .clear, hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.10))
                disclosure.frame = NSRect(x: 0, y: cursor, width: min(width, 210), height: 28)
                disclosure.setAccessibilityIdentifier("dictionary.meanings.disclosure")
                bodyDocument.addSubview(disclosure)
                cursor += 34
            }
        }
        if !word.examples.isEmpty {
            let title = makeLabel("Examples", font: .systemFont(ofSize: 12, weight: .medium), color: ShortcutUIStyle.secondaryTextColor)
            title.frame = NSRect(x: 0, y: cursor + 3, width: width, height: 18)
            bodyDocument.addSubview(title)
            cursor += 26
        }
        let examplesExpanded = expandedExampleKeys.contains(activeMeaningKey)
        for (index, example) in (examplesExpanded ? word.examples : Array(word.examples.prefix(2))).enumerated() {
            cursor = renderExample(example, number: index + 1, at: cursor, width: width)
        }
        essentialContentHeight = cursor
        if entryNeedsTextDisclosure(word, width: width) {
            let expanded = expandedEntryKeys.contains(activeMeaningKey)
            let disclosure = makeDisclosure(
                title: expanded ? "Show shorter definitions and examples" : "Show full definitions and examples",
                identifier: "dictionary.entry.disclosure", action: #selector(toggleEntryText(_:)),
                at: cursor, width: width
            )
            cursor = disclosure.frame.maxY + 6
        }
        if word.examples.count > 2 {
            let disclosure = makeDisclosure(
                title: examplesExpanded ? "Show fewer examples" : "Show \(word.examples.count - 2) more examples",
                identifier: "dictionary.examples.disclosure", action: #selector(toggleExamples(_:)),
                at: cursor, width: width
            )
            cursor = disclosure.frame.maxY + 6
        }
        if !state.aiAdditions.isEmpty { cursor = renderAIAdditions(state.aiAdditions, at: cursor + 8, width: width) }
        return cursor
    }

    private func tokenCounterText(_ sentence: DictionaryPanelSentence) -> String {
        let indices = sentence.tokens.indices.filter { !sentence.tokens[$0].isWhitespace && !sentence.tokens[$0].isPunctuation }
        let position = indices.firstIndex(of: sentence.activeTokenIndex) ?? 0
        return "\(position + 1) / \(max(1, indices.count))"
    }

    private func renderTokenNavigation(_ sentence: DictionaryPanelSentence, at y: CGFloat, x: CGFloat, width: CGFloat) {
        let indices = sentence.tokens.indices.filter { !sentence.tokens[$0].isWhitespace && !sentence.tokens[$0].isPunctuation }
        let position = indices.firstIndex(of: sentence.activeTokenIndex) ?? 0
        let previous = makeNavigationButton(symbol: "chevron.left", label: "Previous sentence token", enabled: position > 0)
        previous.action = #selector(previousToken(_:))
        previous.frame = NSRect(x: x, y: y, width: 30, height: 30)
        let index = makeLabel(tokenCounterText(sentence), font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: ShortcutUIStyle.secondaryTextColor, centered: true)
        index.alignment = .center
        index.cell?.usesSingleLineMode = true
        index.maximumNumberOfLines = 1
        index.frame = NSRect(x: x + 30, y: y, width: width - 62, height: 30)
        index.setAccessibilityLabel("Current sentence token")
        let next = makeNavigationButton(symbol: "chevron.right", label: "Next sentence token", enabled: position < indices.count - 1)
        next.action = #selector(nextToken(_:))
        next.frame = NSRect(x: x + 30 + index.frame.width, y: y, width: 30, height: 30)
        for view in [previous, index, next] { bodyDocument.addSubview(view) }
    }

    private func allKnownSourceLanguagesMatchTarget(_ sentence: DictionaryPanelSentence) -> Bool {
        let words = sentence.tokens.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !words.isEmpty else { return false }
        let target = state.targetLanguage.sourceLanguage.canonicalCode
        let targetScript = ChineseScript(languageTag: state.targetLanguage.rawValue)
        return words.allSatisfy { token in
            let detected = DictionaryLanguageService.detect(token.text, preferred: .automatic)
            // A manual source correction must not suppress a visibly mixed
            // script translation by assigning every token the same override.
            if !detected.isAutomatic && detected.canonicalCode != target { return false }
            if let targetScript, detected.canonicalCode == "zh",
               ChineseScript.detect(token.text) != targetScript { return false }
            let language = token.sourceLanguage.isAutomatic
                ? (state.sourceLanguage.isAutomatic ? detected : state.sourceLanguage)
                : token.sourceLanguage
            if let targetScript, language.canonicalCode == "zh" {
                let sourceScript = ChineseScript(languageTag: language.rawValue) ?? .simplified
                if sourceScript != targetScript { return false }
            }
            return !language.isAutomatic && language.canonicalCode == target
        }
    }

    private static func displayKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func pronunciationKey(_ text: String) -> String {
        displayKey(text).trimmingCharacters(in: CharacterSet(charactersIn: "/[]"))
    }

    @objc private func toggleMeanings(_ sender: NSButton) {
        recordHumanActivity()
        if !expandedMeaningKeys.insert(activeMeaningKey).inserted { expandedMeaningKeys.remove(activeMeaningKey) }
        renderBody(preserveDocumentHeight: false)
    }

    // Keep ordinary definitions complete. Exceptionally long text has a
    // three-line preview, its full accessible value/tooltip, and an explicit
    // expansion control after the essential entry.
    private func entryLabelHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let fullHeight = measuredLabelHeight(text, width: width, font: font)
        return expandedEntryKeys.contains(activeMeaningKey)
            ? fullHeight : min(fullHeight, font.boundingRectForFont.height * 3 + 4)
    }

    private func meaningText(_ meaning: DictionaryPanelMeaning) -> String {
        var text = meaning.definition
        if let translation = meaning.translation, !translation.isEmpty, !Self.hasSameDisplayText(meaning.definition, translation) {
            text += "  · \(translation)"
        }
        if meaning.isAIAddition { text += "  · AI" }
        return text
    }

    private func entryNeedsTextDisclosure(_ word: DictionaryPanelWord, width: CGFloat) -> Bool {
        func exceedsPreview(_ text: String, width: CGFloat, font: NSFont) -> Bool {
            measuredLabelHeight(text, width: width, font: font) > font.boundingRectForFont.height * 3 + 4
        }
        return word.meanings.contains { exceedsPreview(meaningText($0), width: width - 30, font: .systemFont(ofSize: 15)) }
            || word.examples.contains {
                exceedsPreview($0.source, width: width - 40, font: .systemFont(ofSize: 13.5))
                    || $0.translation.map { exceedsPreview($0, width: width - 40, font: .systemFont(ofSize: 12.5)) } == true
            }
    }

    private func defaultMeaningCount(_ meanings: [DictionaryPanelMeaning], word: DictionaryPanelWord, at y: CGFloat, width: CGFloat) -> Int {
        guard meanings.count >= 3 else { return meanings.count }
        let screen = panel.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.insetBy(dx: 16, dy: 16).height ?? DictionaryPanelLayout.panelHeight)
            - scrollView.frame.minY - DictionaryPanelLayout.bodyBottomInset
        let meaningHeight = meanings.prefix(3).reduce(CGFloat.zero) {
            $0 + entryLabelHeight(meaningText($1), width: width - 30, font: .systemFont(ofSize: 15)) + 8
        }
        let exampleHeight = word.examples.prefix(2).reduce(CGFloat.zero) { total, example in
            let source = entryLabelHeight(example.source, width: width - 40, font: .systemFont(ofSize: 13.5))
            let translation = example.translation.flatMap {
                Self.hasSameDisplayText(example.source, $0) ? nil : $0
            }.map { entryLabelHeight($0, width: width - 40, font: .systemFont(ofSize: 12.5)) + 2 } ?? 0
            return total + max(30, source + translation + 6) + 6
        }
        let disclosureHeight: CGFloat = meanings.count > 3 ? 34 : 0
        let examplesTitleHeight: CGFloat = word.examples.isEmpty ? 0 : 26
        return y + meaningHeight + disclosureHeight + examplesTitleHeight + exampleHeight > availableHeight ? 2 : 3
    }

    @objc private func toggleEntryText(_ sender: NSButton) {
        recordHumanActivity()
        if !expandedEntryKeys.insert(activeMeaningKey).inserted { expandedEntryKeys.remove(activeMeaningKey) }
        renderBody(preserveDocumentHeight: false)
    }

    private func makeDisclosure(title: String, identifier: String, action: Selector, at y: CGFloat, width: CGFloat) -> NSButton {
        let disclosure = DictionaryHoverButton(title: title, target: self, action: action)
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 12.5, weight: .medium)
        disclosure.contentTintColor = DictionaryPanelStyle.accentTextColor
        disclosure.configureHover(normal: .clear, hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.10))
        disclosure.frame = NSRect(x: 0, y: y, width: min(width, 250), height: 28)
        disclosure.setAccessibilityIdentifier(identifier)
        bodyDocument.addSubview(disclosure)
        return disclosure
    }

    @objc private func toggleSentenceContext(_ sender: NSButton) {
        recordHumanActivity()
        isSentenceExpanded.toggle()
        renderBody(preserveDocumentHeight: false)
    }

    @objc private func toggleExamples(_ sender: NSButton) {
        recordHumanActivity()
        if !expandedExampleKeys.insert(activeMeaningKey).inserted { expandedExampleKeys.remove(activeMeaningKey) }
        renderBody(preserveDocumentHeight: false)
    }

    @objc private func toggleAIContext(_ sender: NSButton) {
        recordHumanActivity()
        if !expandedContextKeys.insert(activeMeaningKey).inserted { expandedContextKeys.remove(activeMeaningKey) }
        renderBody(preserveDocumentHeight: false)
    }

    private func renderMeaning(
        _ meaning: DictionaryPanelMeaning,
        number: Int?,
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let text = meaningText(meaning)
        let textX: CGFloat
        if let number {
            let numberLabel = makeLabel("\(number)", font: .systemFont(ofSize: 14, weight: .semibold), color: ShortcutUIStyle.primaryTextColor)
            numberLabel.frame = NSRect(x: 0, y: y + 2, width: 24, height: 20)
            numberLabel.setAccessibilityLabel("Meaning \(number)")
            bodyDocument.addSubview(numberLabel)
            textX = 30
        } else {
            textX = 0
        }
        let label = makeLabel(text, font: .systemFont(ofSize: 15), color: ShortcutUIStyle.primaryTextColor)
        let textWidth = max(20, width - textX)
        label.frame = NSRect(x: textX, y: y, width: textWidth, height: entryLabelHeight(text, width: textWidth, font: label.font ?? .systemFont(ofSize: 15)))
        label.maximumNumberOfLines = expandedEntryKeys.contains(activeMeaningKey) ? 0 : 3
        label.toolTip = text
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.setAccessibilityLabel(number.map { "Meaning \($0): \(text)" } ?? "Meaning: \(text)")
        bodyDocument.addSubview(label)
        return y + label.frame.height + 8
    }

    private func renderExample(
        _ example: DictionaryPanelExample,
        number: Int,
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let translation = example.translation.flatMap { value -> String? in
            guard !value.isEmpty, !Self.hasSameDisplayText(example.source, value) else { return nil }
            return value
        }
        let sourceFont = NSFont.systemFont(ofSize: 13.5)
        let translationFont = NSFont.systemFont(ofSize: 12.5)
        let sourceHeight = entryLabelHeight(example.source, width: width - 40, font: sourceFont)
        let translationHeight = translation.map {
            entryLabelHeight($0, width: width - 40, font: translationFont)
        } ?? 0
        let cardHeight = max(
            30,
            sourceHeight
                + (translation == nil ? 0 : translationHeight + 2)
                + 6
        )
        let card = DictionaryPanelSurfaceView(frame: NSRect(
            x: DictionaryPanelLayout.exampleInset,
            y: y,
            width: width - DictionaryPanelLayout.exampleInset,
            height: cardHeight
        ))

        let source = makeLabel(example.source, font: sourceFont, color: ShortcutUIStyle.primaryTextColor)
        source.frame = NSRect(x: 0, y: 0, width: card.bounds.width - 40, height: sourceHeight)
        source.maximumNumberOfLines = expandedEntryKeys.contains(activeMeaningKey) ? 0 : 3
        source.toolTip = example.source
        source.lineBreakMode = .byWordWrapping
        source.cell?.wraps = true
        source.setAccessibilityLabel("Example \(number): \(example.source)")
        card.addSubview(source)

        if let translation {
            let translated = makeLabel(translation, font: translationFont, color: ShortcutUIStyle.secondaryTextColor)
            translated.frame = NSRect(
                x: 0,
                y: source.frame.maxY + 4,
                width: card.bounds.width - 40,
                height: translationHeight
            )
            translated.lineBreakMode = .byWordWrapping
            translated.cell?.wraps = true
            translated.maximumNumberOfLines = expandedEntryKeys.contains(activeMeaningKey) ? 0 : 3
            translated.toolTip = translation
            translated.setAccessibilityLabel("Example translation \(translation)")
            card.addSubview(translated)
        }

        let speak = makeSpeechButton(label: "Speak example \(number)")
        speak.frame = NSRect(x: card.bounds.width - 30, y: 0, width: 30, height: 30)
        speak.tag = number - 1
        speak.target = self
        speak.action = #selector(speakExample(_:))
        card.addSubview(speak)
        bodyDocument.addSubview(card)
        return y + cardHeight + 6
    }

    private func renderAIAdditions(
        _ additions: [String],
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        var cursor = y
        let expanded = expandedContextKeys.contains(activeMeaningKey)
        var needsDisclosure = false
        for addition in additions where !addition.hasPrefix("AI reading:") {
            let text = "AI · " + (addition.hasPrefix("Context: ") ? String(addition.dropFirst(9)) : addition)
            let label = makeLabel(text, font: .systemFont(ofSize: 12.5), color: ShortcutUIStyle.secondaryTextColor)
            let fullHeight = measuredLabelHeight(text, width: width, font: label.font!)
            let previewHeight = min(fullHeight, label.font!.boundingRectForFont.height * 3 + 4)
            needsDisclosure = needsDisclosure || fullHeight > previewHeight
            label.frame = NSRect(x: 0, y: cursor, width: width, height: expanded ? fullHeight : previewHeight)
            label.maximumNumberOfLines = expanded ? 0 : 3
            label.toolTip = text
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.setAccessibilityLabel("AI addition: \(addition)")
            bodyDocument.addSubview(label)
            cursor += label.frame.height + 8
        }
        if needsDisclosure {
            let disclosure = makeDisclosure(
                title: expanded ? "Show less AI context" : "Show full AI context",
                identifier: "dictionary.context.disclosure", action: #selector(toggleAIContext(_:)),
                at: cursor, width: width
            )
            cursor = disclosure.frame.maxY + 6
        }
        return cursor
    }

    private func renderAttribution(
        _ attribution: (name: String, url: URL?),
        at y: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        attributionURLsByTag.removeAll()
        attributionURL = attribution.url
        let components = attribution.name
            .split(separator: "·", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let names = components.isEmpty ? [attribution.name] : components
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        var cursorX: CGFloat = 0
        var cursorY = y
        var row = 0

        for (nameIndex, name) in names.enumerated() {
            let url = Self.attributionURL(for: name, fallback: attribution.url)
            let title = url == nil ? name : "\(name) ↗"
            let measuredWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 8
            let buttonWidth = min(width, max(44, measuredWidth))
            if cursorX > 0, cursorX + buttonWidth > width {
                row += 1
                cursorX = 0
                cursorY += 22
            }

            let link = DictionaryHoverButton(title: title, target: self, action: #selector(openAttribution(_:)))
            link.isBordered = false
            link.focusRingType = .default
            link.alignment = .left
            link.font = font
            link.contentTintColor = ShortcutUIStyle.secondaryTextColor
            link.configureHover(
                normal: .clear,
                hover: ShortcutUIStyle.secondaryTextColor.withAlphaComponent(0.10)
            )
            link.frame = NSRect(x: cursorX, y: cursorY, width: buttonWidth, height: 19)
            link.tag = row * 100 + nameIndex
            link.setAccessibilityLabel("Dictionary attribution \(name)")
            link.setAccessibilityHelp(url == nil ? "Attribution: \(name)" : "Open \(name) attribution link.")
            link.toolTip = url == nil ? name : "Open \(name)"
            if let url {
                attributionURLsByTag[link.tag] = url
            }
            bodyDocument.addSubview(link)
            cursorX += buttonWidth + 10
        }
        return cursorY + 23
    }

    private var attributionURL: URL?

    private static func attributionURL(for name: String, fallback: URL?) -> URL? {
        let normalized = name.lowercased()
        if normalized.contains("wiktionary") {
            if let fallback, fallback.host?.localizedCaseInsensitiveContains("wiktionary") == true {
                return fallback
            }
            return URL(string: "https://www.wiktionary.org/")
        }
        if normalized.contains("cc by-sa") || normalized.contains("creative commons") {
            return URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")
        }
        if normalized.contains("freedictionaryapi") {
            return URL(string: "https://freedictionaryapi.com/")
        }
        return fallback
    }

    private static func lookupDisplayText(_ query: String) -> String {
        query.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func hasSameDisplayText(_ lhs: String, _ rhs: String) -> Bool {
        let normalize: (String) -> String = { value in
            value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(lhs) == normalize(rhs)
    }

    private func renderError(_ message: String, at y: CGFloat, width: CGFloat) -> CGFloat {
        let canRetry = !state.query.isEmpty
            && (state.presentationMode == .translate || state.mode != .manual)
            && !isKnownNoEntryError(message)
            && !message.hasPrefix("Set up an AI provider")
        let label = makeLabel(compactErrorMessage(message, width: width), font: .systemFont(ofSize: 12.5), color: ShortcutUIStyle.warningAccentColor)
        let textWidth = width - (canRetry ? 76 : 0)
        label.frame = NSRect(x: 0, y: y + 4, width: textWidth, height: measuredLabelHeight(label.stringValue, width: textWidth, font: label.font!))
        label.cell?.wraps = true
        label.toolTip = message
        label.setAccessibilityLabel((state.presentationMode == .translate ? "Translation error: " : "Dictionary error: ") + message)
        label.setAccessibilityValue(message)
        label.setAccessibilityIdentifier("dictionary.status.error")
        bodyDocument.addSubview(label)
        if canRetry {
            let retry = DictionaryHoverButton(title: "Retry", target: self, action: #selector(retryPressed(_:)))
            retry.isBordered = false
            retry.font = .systemFont(ofSize: 12.5, weight: .medium)
            retry.contentTintColor = DictionaryPanelStyle.accentTextColor
            retry.configureHover(normal: .clear, hover: ShortcutUIStyle.accentColor.withAlphaComponent(0.10))
            retry.frame = NSRect(x: width - 66, y: y, width: 66, height: 28)
            retry.setAccessibilityIdentifier("dictionary.status.retry")
            retry.setAccessibilityLabel(state.presentationMode == .translate
                                        ? "Retry translation" : "Retry dictionary lookup")
            bodyDocument.addSubview(retry)
        }
        return max(label.frame.maxY, y + 28) + 6
    }

    private func compactErrorMessage(_ message: String, width: CGFloat) -> String {
        let normalized = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Lookup unavailable" }

        if state.mode == .manual {
            let captureMessage = normalized.lowercased()
            if captureMessage.contains("accessibility") {
                return "Enable Accessibility or type to look up."
            }
            if captureMessage.contains("no text captured") {
                return "No text captured. Type to look up."
            }
        }

        if isKnownNoEntryError(normalized) {
            return width >= 500 ? "No entry found · edit the word or source" : "No entry found · edit the word"
        }

        // Retain the full error in accessibility and the tooltip while the
        // footer uses a short actionable summary.
        let maximumCharacters = width >= 500 ? 58 : 32
        guard normalized.count > maximumCharacters else { return normalized }
        return "Lookup failed. Try again."
    }

    private func isKnownNoEntryError(_ message: String) -> Bool {
        let normalized = message
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized == "no dictionary entry was found for that word."
            || normalized == "no dictionary entry was found for that word"
            || normalized.contains("no dictionary entry was found")
    }

    // MARK: Actions

    private func submitLookup() {
        let query = currentDraft
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordHumanActivity()
            // Let the coordinator cancel any in-flight generation before the
            // local manual state is redrawn. The empty submission is also the
            // stable callback used by older integrations that do not expose a
            // separate clear handler.
            submitHandler?("")
            state = DictionaryPanelViewState(
                query: "",
                sourceLanguage: state.sourceLanguage,
                detectedSourceLanguage: state.detectedSourceLanguage,
                targetLanguage: state.targetLanguage,
                mode: .manual,
                presentationMode: state.presentationMode
            )
            updateInterface()
            return
        }
        beginPlacementOperation()
        submitHandler?(query)
    }

    @objc private func toggleModePressed(_ sender: NSButton) {
        recordHumanActivity()
        toggleModeHandler?(currentDraft)
    }

    @objc private func submitLookupButton(_ sender: NSButton) {
        submitLookup()
    }

    private func dismissFromUser() {
        guard !isDismissing else { return }
        cancelSearchAnimation()
        recordHumanActivity()
        isDismissing = true
        sourceEditTask?.cancel()
        clickAwayDismissal.stop()
        historyPopover?.close()
        historyPopover = nil
        historyPopoverController = nil
        panel.orderOut(nil)
        dismissHandler?()
    }

    private var placementGeometryEnabled: Bool {
        if case .active = presentationMode { return true }
        return usesSyntheticPlacementGeometry
    }

    private func activeScreenGeometry() -> DictionaryPanelScreenGeometry? {
        let screens = screenGeometryProvider()
        let pointer = pointerLocationProvider()
        if let underPointer = screens.first(where: { $0.frame.contains(pointer) }) {
            return underPointer
        }
        if let mainScreen = NSScreen.main,
           let main = screens.first(where: { $0.frame == mainScreen.frame }) {
            return main
        }
        return screens.first
    }

    private func screenGeometry(containing frame: NSRect) -> DictionaryPanelScreenGeometry? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screenGeometryProvider().first(where: { $0.frame.contains(center) })
    }

    private func currentPlacementGeometry() -> DictionaryPanelScreenGeometry? {
        let screens = screenGeometryProvider()
        if let preferred = placementSession.preferredScreenFrame,
           let retained = screens.first(where: { $0.frame == preferred }) {
            return retained
        }
        return screenGeometry(containing: panel.frame) ?? activeScreenGeometry()
    }

    private func visibleFrameForCurrentPanel() -> NSRect? {
        currentPlacementGeometry()?.visibleFrame
    }

    private func beginPlacementOperation() {
        let active = activeScreenGeometry()
        let expired = placementSession.beginOperation(
            at: placementClock(),
            activeScreenFrame: active?.frame
        )
        if expired, panel.isVisible, placementGeometryEnabled {
            applyCurrentPlacement()
        }
    }

    private func recordHumanActivity() {
        placementSession.recordHumanActivity(at: placementClock())
    }

    private func applyCurrentPlacement() {
        guard placementGeometryEnabled,
              let geometry = currentPlacementGeometry()
        else { return }
        let desired = DictionaryPanelPlacementGeometry.frame(
            current: panel.frame,
            size: panel.frame.size,
            center: !placementSession.isUserMoved,
            visibleFrame: geometry.visibleFrame
        )
        placementSession.retainScreen(geometry.frame)
        applyWindowFrame(desired)
    }

    private func frameForAutomaticResize(
        from current: NSRect,
        to size: NSSize,
        visibleFrame: NSRect?
    ) -> NSRect {
        guard placementGeometryEnabled, let visibleFrame else {
            return NSRect(
                x: current.minX,
                y: current.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }
        return DictionaryPanelPlacementGeometry.frame(
            current: current,
            size: size,
            center: !placementSession.isUserMoved,
            visibleFrame: visibleFrame
        )
    }

    private func applyWindowFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        let sizeChanged = panel.frame.size != frame.size
        isResizingPanel = sizeChanged
        withProgrammaticFrameChange {
            panel.setFrame(frame, display: false)
            if sizeChanged {
                panel.contentView?.layoutSubtreeIfNeeded()
                layoutFramesForPanelSize()
            }
        }
        isResizingPanel = false
        if sizeChanged {
            renderBody()
        }
    }

    private func withProgrammaticFrameChange(_ change: () -> Void) {
        programmaticFrameChangeDepth += 1
        defer { programmaticFrameChangeDepth -= 1 }
        change()
    }

    private func fitPanelToState() {
        guard !isResizingPanel else { return }
        let isNewQuery = lastSizedQuery != state.query
            || lastSizedPresentationMode != state.presentationMode
        guard isNewQuery else { return }
        isUserSizedForQuery = false
        let compact = state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.word == nil
            && state.sentence == nil
            && !state.isLoading
        let isInitialLoading = state.isLoading
            && state.word == nil
            && state.errorMessage == nil
        let substantialText = state.query.count >= 160 || state.query.filter({ $0 == "\n" }).count >= 4
        let preferredWidth: CGFloat = substantialText ? (state.query.count >= 1_000 ? 920 : 800) : panel.frame.width
        let preferredHeight = substantialText ? CGFloat(640) : compact
            ? DictionaryPanelLayout.compactPanelHeight
            : DictionaryPanelLayout.minimumPanelHeight
        let visibleFrame = visibleFrameForCurrentPanel()
        let usable = visibleFrame?.insetBy(dx: 16, dy: 16)
        let targetHeight = min(preferredHeight, usable?.height ?? preferredHeight)
        let targetWidth = min(preferredWidth, usable?.width ?? preferredWidth)
        guard abs(panel.frame.height - targetHeight) > 1 || abs(panel.frame.width - targetWidth) > 1 else {
            lastSizedQuery = state.query
            lastSizedPresentationMode = state.presentationMode
            lastAutomaticPanelSize = panel.frame.size
            needsContentSettlement = !isInitialLoading
            return
        }

        let previousFrame = panel.frame
        isResizingPanel = true
        withProgrammaticFrameChange {
            panel.setContentSize(NSSize(width: targetWidth, height: targetHeight))
            let resizedFrame = panel.frame
            let resolved = frameForAutomaticResize(
                from: previousFrame,
                to: resizedFrame.size,
                visibleFrame: visibleFrame
            )
            panel.setFrameOrigin(resolved.origin)
            updateFramesForPanelSize()
        }
        isResizingPanel = false
        lastSizedQuery = state.query
        lastSizedPresentationMode = state.presentationMode
        lastAutomaticPanelSize = panel.frame.size
        needsContentSettlement = !isInitialLoading
    }

    private func updateFramesForPanelSize() {
        layoutFramesForPanelSize()
        if !isResizingPanel {
            renderBody()
        }
    }

    private func layoutFramesForPanelSize() {
        let target: CGFloat = isSearchCollapsed ? 0 : 1
        if searchAnimationTarget != target {
            cancelSearchAnimation()
            searchExpansion = target
        }
        let bounds = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 620)
        background.frame = bounds
        let narrow = bounds.width < 480
        let verticalOffset: CGFloat = narrow ? 38 : 0
        searchSurface.frame = NSRect(
            x: DictionaryPanelLayout.searchInset,
            y: DictionaryPanelLayout.searchY + verticalOffset,
            width: max(260, bounds.width - DictionaryPanelLayout.searchInset * 2),
            height: 24 + (DictionaryPanelLayout.searchHeight - 24) * searchExpansion
        )
        let fullyCollapsed = searchExpansion <= 0.001
        lookupField.isHidden = fullyCollapsed
        lookupButton.isHidden = fullyCollapsed || state.isLoading
        clearButton.isHidden = fullyCollapsed
        lookupField.alphaValue = searchExpansion
        clearButton.alphaValue = searchExpansion
        progressIndicator.alphaValue = searchExpansion
        progressIndicator.isHidden = fullyCollapsed
        updateLookupButtonState()
        searchSurface.layer?.backgroundColor = ShortcutUIStyle.raisedSurfaceColor.withAlphaComponent(searchExpansion).cgColor
        searchSurface.layer?.borderWidth = searchExpansion
        searchSurface.layer?.cornerRadius = ShortcutUIStyle.inputCornerRadius
        searchSurface.lineOpacity = 1 - searchExpansion
        searchSurface.needsDisplay = true
        clearButton.frame = NSRect(
            x: searchSurface.bounds.width
                - DictionaryPanelLayout.lookupTrailingInset
                - DictionaryPanelLayout.lookupClearWidth,
            y: clearButton.frame.minY,
            width: DictionaryPanelLayout.lookupClearWidth,
            height: clearButton.frame.height
        )
        lookupButton.frame = NSRect(
            x: clearButton.frame.minX
                - DictionaryPanelLayout.controlGap
                - DictionaryPanelLayout.lookupButtonWidth,
            y: lookupButton.frame.minY,
            width: DictionaryPanelLayout.lookupButtonWidth,
            height: lookupButton.frame.height
        )
        lookupField.frame.size.width = max(
            160,
            lookupButton.frame.minX
                - DictionaryPanelLayout.controlGap
                - lookupField.frame.minX
        )
        let bodyY = DictionaryPanelLayout.scrollY + verticalOffset - 28 * (1 - searchExpansion)
        scrollView.frame = NSRect(
            x: DictionaryPanelLayout.outerInset,
            y: bodyY,
            width: max(260, bounds.width - DictionaryPanelLayout.outerInset * 2),
            height: max(80, bounds.height - bodyY - DictionaryPanelLayout.outerInset)
        )

        let right = bounds.width - DictionaryPanelLayout.headerInset
        closeButton.frame = NSRect(x: right - 32, y: DictionaryPanelLayout.headerY, width: 32, height: 32)
        historyButton.frame = NSRect(x: right - 70, y: DictionaryPanelLayout.headerY, width: 32, height: 32)
        let languageY = DictionaryPanelLayout.headerY + (narrow ? 38 : 0)
        let menuWidth: CGFloat = narrow ? (bounds.width - 44 - 24) / 2 : 112
        let menuX: CGFloat = narrow ? DictionaryPanelLayout.headerInset : historyButton.frame.minX - 250
        sourcePopup.frame = NSRect(x: menuX, y: languageY, width: menuWidth, height: 32)
        languageArrow.frame = NSRect(x: sourcePopup.frame.maxX + 2, y: languageY + 6, width: 20, height: 20)
        targetPopup.frame = NSRect(x: sourcePopup.frame.maxX + 24, y: languageY, width: menuWidth, height: 32)
        headerTitle.frame = NSRect(x: DictionaryPanelLayout.headerInset, y: DictionaryPanelLayout.headerY,
                                  width: max(88, (narrow ? historyButton.frame.minX : menuX) - DictionaryPanelLayout.headerInset - 8), height: 32)
        modeButton.frame = NSRect(x: DictionaryPanelLayout.headerInset + 112,
                                  y: DictionaryPanelLayout.headerY, width: 32, height: 32)
        if state.isLoading { progressIndicator.frame = lookupButton.frame.insetBy(dx: 7, dy: 7) }
        bodyDocument.setFrameSize(NSSize(width: scrollView.contentView.bounds.width,
                                         height: max(bodyDocument.frame.height, scrollView.contentView.bounds.height)))
    }

    private func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor,
        centered: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if centered {
            label.cell = DictionaryCenteredTextFieldCell(textCell: text)
        }
        label.font = font
        label.textColor = color
        label.backgroundColor = .clear
        label.isEditable = false
        label.isSelectable = false
        label.cell?.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func measuredLabelHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        // NSTextField adds cell insets to its text layout. Measuring only the
        // string's glyph bounds can clip the last line of wrapped definitions.
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.isBordered = false
        cell.isBezeled = false
        cell.usesSingleLineMode = false
        cell.lineBreakMode = .byWordWrapping
        cell.wraps = true
        return max(19, ceil(cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: max(20, width), height: 10_000
        )).height))
    }

    private func makeSpeechButton(label: String) -> NSButton {
        let button = DictionaryHoverButton(frame: .zero)
        button.target = self
        button.isBordered = false
        button.focusRingType = .default
        button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: label)?.withSymbolConfiguration(
            .init(pointSize: 14, weight: .medium)
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = ShortcutUIStyle.primaryTextColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 15
        button.configureHover(
            normal: ShortcutUIStyle.primaryTextColor.withAlphaComponent(0.10),
            hover: ShortcutUIStyle.primaryTextColor.withAlphaComponent(0.20)
        )
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp("Speak this text using the selected language voice.")
        button.toolTip = label
        return button
    }

    private func makeNavigationButton(symbol: String, label: String, enabled: Bool) -> NSButton {
        let button = DictionaryHoverButton(frame: .zero)
        button.target = self
        button.isBordered = false
        button.focusRingType = .default
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .semibold)
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = enabled ? ShortcutUIStyle.primaryTextColor : DictionaryPanelStyle.placeholderTextColor
        button.isEnabled = enabled
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.configureHover(
            normal: ShortcutUIStyle.primaryTextColor.withAlphaComponent(enabled ? 0.08 : 0.03),
            hover: ShortcutUIStyle.primaryTextColor.withAlphaComponent(enabled ? 0.16 : 0.04)
        )
        button.setAccessibilityLabel(label)
        let keyHint = symbol.contains("left") ? "Option-Left" : "Option-Right"
        button.setAccessibilityHelp("\(label). Press \(keyHint) when the lookup field is not being edited.")
        button.toolTip = "\(label) · \(keyHint)"
        return button
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String else { return }
        beginPlacementOperation()
        let source = DictionarySourceLanguage(rawValue: rawValue)
        state = DictionaryPanelViewState(
            query: state.query,
            sourceLanguage: source,
            detectedSourceLanguage: state.detectedSourceLanguage,
            targetLanguage: state.targetLanguage,
            mode: state.mode,
            presentationMode: state.presentationMode,
            paragraphTranslation: state.paragraphTranslation,
            isLoading: state.isLoading,
            errorMessage: state.errorMessage,
            word: state.word,
            sentence: state.sentence,
            aiAdditions: state.aiAdditions,
            attributionName: state.attributionName,
            attributionURL: state.attributionURL
        )
        sourceChangeHandler?(source)
    }

    @objc private func showHistoryPopover(_ sender: NSButton) {
        recordHumanActivity()
        historyPopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let historyController = DictionaryHistoryPopoverController(
            items: historyItems,
            errorMessage: historyError,
            onSelect: { [weak self, weak popover] item in
                guard let self else { return }
                popover?.close()
                self.historyPopover = nil
                self.historyPopoverController = nil
                self.beginPlacementOperation()
                self.historySelectHandler?(item)
            },
            onDelete: { [weak self] id in
                guard let self else { return }
                self.recordHumanActivity()
                self.historyItems.removeAll { $0.id == id }
                self.historyError = nil
                self.historyPopoverController?.update(items: self.historyItems, errorMessage: nil)
                self.historyDeleteHandler?(id)
            },
            onClear: { [weak self] in
                guard let self else { return }
                self.recordHumanActivity()
                self.historyItems.removeAll()
                self.historyError = nil
                self.historyPopoverController?.update(items: [], errorMessage: nil)
                self.historyClearHandler?()
            }
        )
        popover.contentViewController = historyController
        historyPopoverController = historyController
        historyPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let target = DictionaryTargetLanguage(rawValue: raw) else { return }
        guard state.presentationMode != .translate
                || !DictionaryTranslationLanguagePolicy.isSameLanguage(resolvedSourceLanguage.rawValue, raw)
        else {
            updateInterface()
            return
        }
        beginPlacementOperation()
        state = DictionaryPanelViewState(query: state.query, sourceLanguage: state.sourceLanguage,
            detectedSourceLanguage: state.detectedSourceLanguage, targetLanguage: target, mode: state.mode,
            presentationMode: state.presentationMode, paragraphTranslation: state.paragraphTranslation,
            isLoading: state.isLoading, errorMessage: state.errorMessage, word: state.word, sentence: state.sentence,
            aiAdditions: state.aiAdditions, attributionName: state.attributionName, attributionURL: state.attributionURL)
        targetChangeHandler?(target)
        updateInterface()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        dismissFromUser()
    }

    @objc private func clearLookup(_ sender: NSButton) {
        recordHumanActivity()
        submitHandler?("")
        state = DictionaryPanelViewState(
            query: "",
            sourceLanguage: state.sourceLanguage,
            detectedSourceLanguage: state.detectedSourceLanguage,
            targetLanguage: state.targetLanguage,
            mode: .manual,
            presentationMode: state.presentationMode
        )
        updateInterface()
        panel.makeFirstResponder(lookupField)
    }

    @objc private func retryPressed(_ sender: NSButton) {
        beginPlacementOperation()
        retryHandler?()
    }

    @objc private func openPermissionSettings(_ sender: NSButton) {
        recordHumanActivity()
        permissionSettingsHandler?()
    }

    @objc private func openAttribution(_ sender: NSButton) {
        guard let url = attributionURLsByTag[sender.tag] ?? attributionURL else { return }
        recordHumanActivity()
        NSWorkspace.shared.open(url)
    }

    private var effectiveSpeechLanguage: DictionarySourceLanguage {
        if let sentence = state.sentence,
           sentence.tokens.indices.contains(sentence.activeTokenIndex)
        {
            let tokenLanguage = sentence.tokens[sentence.activeTokenIndex].sourceLanguage
            if !tokenLanguage.isAutomatic {
                return tokenLanguage
            }
        }
        guard state.sourceLanguage.isAutomatic else { return state.sourceLanguage }
        if let detected = state.detectedSourceLanguage, !detected.isAutomatic {
            return detected
        }
        let detected = DictionaryLanguageService.detect(state.query, preferred: .automatic)
        return detected.isAutomatic ? .english : detected
    }

    @objc private func speakWord(_ sender: NSButton) {
        let text: String
        if let word = state.word {
            text = word.originalText.isEmpty ? word.headword : word.originalText
        } else {
            guard let sentence = state.sentence,
                  sentence.tokens.indices.contains(sentence.activeTokenIndex)
            else { return }
            let token = sentence.tokens[sentence.activeTokenIndex]
            guard !token.isWhitespace, !token.isPunctuation,
                  !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            text = token.text
        }
        recordHumanActivity()
        speakHandler?(DictionarySpeechRequest(
            text: text,
            language: effectiveSpeechLanguage,
            kind: .word
        ))
    }

    @objc private func speakExample(_ sender: NSButton) {
        guard let example = state.word?.examples.indices.contains(sender.tag) == true
            ? state.word?.examples[sender.tag]
            : nil
        else { return }
        recordHumanActivity()
        speakHandler?(DictionarySpeechRequest(
            text: example.source,
            language: example.language == .automatic ? effectiveSpeechLanguage : example.language,
            kind: .example
        ))
    }

    @objc private func speakTranslation(_ sender: NSButton) {
        guard let translated = state.paragraphTranslation else { return }
        recordHumanActivity()
        speakHandler?(DictionarySpeechRequest(
            text: translated,
            language: state.targetLanguage.sourceLanguage,
            kind: .sentence
        ))
    }

    @objc private func previousToken(_ sender: NSButton) {
        selectAdjacentToken(delta: -1)
    }

    @objc private func nextToken(_ sender: NSButton) {
        selectAdjacentToken(delta: 1)
    }

    private func selectAdjacentToken(delta: Int) {
        guard let sentence = state.sentence else { return }
        let navigable = sentence.tokens.indices.filter {
            !sentence.tokens[$0].isWhitespace && !sentence.tokens[$0].isPunctuation
        }
        guard let position = navigable.firstIndex(of: sentence.activeTokenIndex) else { return }
        let destination = position + delta
        guard navigable.indices.contains(destination) else { return }
        beginPlacementOperation()
        selectTokenHandler?(sentence.tokens[navigable[destination]])
    }
}
