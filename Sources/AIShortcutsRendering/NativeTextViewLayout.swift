import AppKit

@MainActor
public enum NativeTextViewLayout {
    @discardableResult
    public static func fitDocumentView(
        _ textView: NSTextView,
        minimumHeight: CGFloat = 0
    ) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let fallbackHeight = max(
                minimumHeight,
                NSLayoutManager().defaultLineHeight(for: font)
                    + textView.textContainerInset.height * 2
            )
            textView.frame.size.height = fallbackHeight
            return fallbackHeight
        }

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(
            width: max(
                1,
                textView.frame.width - textView.textContainerInset.width * 2
            ),
            height: CGFloat.greatestFiniteMagnitude
        )

        let characterRange = NSRange(
            location: 0,
            length: textView.textStorage?.length ?? 0
        )
        if characterRange.length > 0 {
            layoutManager.invalidateLayout(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
        }
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var maximumY: CGFloat = 0
        if glyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineFragmentRect,
                usedRect,
                _,
                _,
                _ in
                maximumY = max(maximumY, lineFragmentRect.maxY, usedRect.maxY)
            }
        } else {
            maximumY = layoutManager.defaultLineHeight(
                for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            )
        }

        let measuredHeight = ceil(
            maximumY + textView.textContainerInset.height * 2
        )
        textView.frame.size.height = max(minimumHeight, measuredHeight)
        textView.needsLayout = true
        return measuredHeight
    }
}
