import AppKit

/// Overlay view that shows enclosing scope declarations pinned at the top
/// of the editor when they've scrolled out of view ("sticky scroll").
class StickyScrollView: NSView {

    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    /// Callback when a sticky line is clicked: (characterOffset)
    var onLineClicked: ((Int) -> Void)?

    private let bgColor = NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 0.97)
    private let borderColor = NSColor(white: 0.25, alpha: 1.0)
    private let lineHeight: CGFloat = 18

    /// Currently displayed scope lines: (lineText, charOffset)
    private var stickyLines: [(text: String, charOffset: Int)] = []

    /// Maximum number of sticky scope lines
    private let maxStickyLines = 3

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Update the sticky lines based on current scroll position
    func updateStickyLines() {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else {
            updateVisibility([])
            return
        }

        let text = textView.string as NSString
        guard text.length > 0 else {
            updateVisibility([])
            return
        }

        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Find the first visible line
        let firstVisibleCharIdx = visibleCharRange.location

        // Walk backwards to find enclosing scope declarations
        let scopes = findEnclosingScopes(in: text, at: firstVisibleCharIdx)
        updateVisibility(scopes)
    }

    /// Scope declaration patterns (simplified — look for lines ending with `{`)
    private static let scopePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^\s*((?:(?:public|private|internal|fileprivate|open|static|final|override|class|@\w+)\s+)*(?:func|class|struct|enum|protocol|extension|init|deinit|var|subscript|if|else|for|while|guard|switch|do|catch)\b[^{]*)\{"#,
            options: [.anchorsMatchLines]
        )
    }()

    private func findEnclosingScopes(in text: NSString, at position: Int) -> [(text: String, charOffset: Int)] {
        // Get lines up to position
        var scopes: [(text: String, charOffset: Int, depth: Int)] = []
        var braceDepth = 0
        var lineStart = 0
        var lineNum = 0

        let scanEnd = min(position + 200, text.length) // slight over-scan for partial line

        while lineStart < scanEnd && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineText = text.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // Track brace depth from this line
            var openCount = 0
            var closeCount = 0
            for ch in lineText {
                if ch == "{" { openCount += 1 }
                if ch == "}" { closeCount += 1 }
            }

            // If this line opens a scope (has `{` and matches a scope pattern)
            if openCount > closeCount, lineRange.location < position {
                if let regex = Self.scopePattern {
                    let matches = regex.matches(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))
                    if !matches.isEmpty {
                        scopes.append((text: lineText, charOffset: lineRange.location, depth: braceDepth))
                    }
                }
            }

            braceDepth += openCount - closeCount

            // Remove scopes that have been closed
            scopes = scopes.filter { $0.depth < braceDepth || $0.charOffset >= position }

            lineStart = NSMaxRange(lineRange)
            lineNum += 1
        }

        // Only show scopes whose declaration is above the visible area
        let result = scopes
            .filter { $0.charOffset < position }
            .suffix(maxStickyLines)
            .map { (text: $0.text, charOffset: $0.charOffset) }

        return Array(result)
    }

    private func updateVisibility(_ newLines: [(text: String, charOffset: Int)]) {
        let changed = newLines.count != stickyLines.count ||
            zip(newLines, stickyLines).contains { $0.charOffset != $1.charOffset }

        stickyLines = newLines

        if stickyLines.isEmpty {
            isHidden = true
        } else {
            isHidden = false
            // Resize height to fit lines
            let newHeight = CGFloat(stickyLines.count) * lineHeight + 1 // +1 for border
            if abs(frame.height - newHeight) > 0.5 {
                frame.size.height = newHeight
                superview?.needsLayout = true
            }
            if changed {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        bounds.fill()

        guard let textView = textView else { return }

        let font = (textView.textStorage?.length ?? 0) > 0
            ? (textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let smallFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize - 1) ?? font

        let attrs: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: NSColor(white: 0.65, alpha: 1.0),
        ]

        for (i, line) in stickyLines.enumerated() {
            let y = CGFloat(i) * lineHeight
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let displayText = trimmed as NSString
            let point = NSPoint(x: 8, y: y + (lineHeight - smallFont.pointSize) / 2)
            displayText.draw(at: point, withAttributes: attrs)
        }

        // Bottom border
        borderColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let lineIndex = Int(localPoint.y / lineHeight)
        guard lineIndex >= 0, lineIndex < stickyLines.count else { return }
        onLineClicked?(stickyLines[lineIndex].charOffset)
    }
}
