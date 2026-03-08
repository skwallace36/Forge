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

    // MARK: - Toggle Comment (⌘/)

    @objc func toggleComment(_ sender: Any?) {
        guard let ts = textStorage else { return }
        let text = ts.string as NSString
        let sel = selectedRange()

        // Get the range of all affected lines
        let lineRange = text.lineRange(for: sel)
        let linesText = text.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        // Determine if we should comment or uncomment
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = nonEmptyLines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//")
        }

        var newLines: [String] = []
        for line in lines {
            if allCommented {
                // Uncomment: remove first occurrence of "// " or "//"
                if let range = line.range(of: "// ") {
                    var newLine = line
                    newLine.removeSubrange(range)
                    newLines.append(newLine)
                } else if let range = line.range(of: "//") {
                    var newLine = line
                    newLine.removeSubrange(range)
                    newLines.append(newLine)
                } else {
                    newLines.append(line)
                }
            } else {
                // Comment: add "// " at the beginning of each line (after leading whitespace)
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    newLines.append(line)
                } else {
                    // Find indent level
                    let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                    let rest = line.dropFirst(indent.count)
                    newLines.append(String(indent) + "// " + rest)
                }
            }
        }

        let newText = newLines.joined(separator: "\n")
        if shouldChangeText(in: lineRange, replacementString: newText) {
            ts.replaceCharacters(in: lineRange, with: newText)
            didChangeText()

            // Restore selection approximately
            let newRange = NSRange(location: lineRange.location, length: (newText as NSString).length)
            setSelectedRange(newRange)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘/ for toggle comment
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "/" {
            toggleComment(nil)
            return
        }

        // ⌘⌥[ for fold (placeholder)
        // ⌘⌥] for unfold (placeholder)

        super.keyDown(with: event)
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
