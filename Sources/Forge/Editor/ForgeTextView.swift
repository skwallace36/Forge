import AppKit

/// Custom NSTextView subclass for code editing.
class ForgeTextView: NSTextView {

    /// Tab width in spaces
    var tabWidth: Int = 4

    /// Current line highlight color
    var currentLineHighlightColor: NSColor = NSColor(white: 1.0, alpha: 0.06)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Set up default paragraph style with tab stops
        let paragraphStyle = NSMutableParagraphStyle()
        let charWidth = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            .advancement(forGlyph: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).glyph(withName: " ")).width
        paragraphStyle.defaultTabInterval = charWidth * CGFloat(tabWidth)
        paragraphStyle.tabStops = []
        defaultParagraphStyle = paragraphStyle
    }

    override func insertTab(_ sender: Any?) {
        // Insert spaces instead of tab
        let spaces = String(repeating: " ", count: tabWidth)
        insertText(spaces, replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        // Auto-indent: match leading whitespace of current line
        guard let textStorage = textStorage else {
            super.insertNewline(sender)
            return
        }

        let text = textStorage.string
        let nsText = text as NSString
        let cursorLocation = selectedRange().location

        // Find the start of the current line
        let lineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let lineStart = lineRange.location
        let lineText = nsText.substring(with: NSRange(location: lineStart, length: cursorLocation - lineStart))

        // Extract leading whitespace
        var indent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }

        // Check if the line ends with { or ( — add extra indent
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") {
            indent += String(repeating: " ", count: tabWidth)
        }

        insertText("\n" + indent, replacementRange: selectedRange())
    }

    // MARK: - Current Line Highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        highlightCurrentLine()
    }

    private func highlightCurrentLine() {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        let text = string as NSString
        guard text.length > 0 else { return }

        let selectedRange = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(selectedRange.location, text.length), length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerInset.height

        currentLineHighlightColor.setFill()
        lineRect.fill()
    }
}
