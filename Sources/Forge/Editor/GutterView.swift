import AppKit

/// Line number gutter drawn alongside the text view.
class GutterView: NSView {

    weak var textView: NSTextView?
    var theme: Theme?
    var diagnosticLines: Set<Int> = [] // 0-indexed line numbers with diagnostics
    /// Diagnostic messages indexed by 0-indexed line number
    var diagnosticMessages: [Int: String] = [:]
    var changedLines: [Int: String] = [:] // 0-indexed: "added" or "modified"

    /// Set of 0-indexed line numbers that start a foldable block (line ends with `{`)
    var foldableLines: Set<Int> = []

    /// Set of 0-indexed line numbers that are currently folded
    var foldedLines: Set<Int> = []

    /// Callback when a fold marker is clicked: (lineNumber: 0-indexed)
    var onFoldToggle: ((Int) -> Void)?

    /// Anchor line range for drag-to-select in gutter
    private var dragAnchorLineRange: NSRange?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !diagnosticMessages.isEmpty else {
            toolTip = nil
            return
        }

        let lineNum = lineNumberAtPoint(convert(event.locationInWindow, from: nil))
        if let line = lineNum, let message = diagnosticMessages[line] {
            toolTip = message
        } else {
            toolTip = nil
        }
    }

    private func lineNumberAtPoint(_ localPoint: NSPoint) -> Int? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let text = textView.string as NSString
        guard text.length > 0 else { return nil }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let textViewY = localPoint.y + visibleRect.origin.y
        let adjustedPoint = NSPoint(x: 0, y: textViewY - textView.textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard charIndex < text.length else { return nil }

        return Self.countNewlines(in: text, upTo: charIndex)
    }

    /// Count newlines in text up to (not including) the given character index.
    /// O(n) scan but avoids allocating substring arrays — much faster than components(separatedBy:).
    private static func countNewlines(in text: NSString, upTo index: Int) -> Int {
        var count = 0
        let limit = min(index, text.length)
        // Use UTF-16 buffer for fast access
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: limit)
        defer { buffer.deallocate() }
        text.getCharacters(buffer, range: NSRange(location: 0, length: limit))
        let newline: unichar = 0x0A // \n
        for i in 0..<limit {
            if buffer[i] == newline { count += 1 }
        }
        return count
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            super.mouseDown(with: event)
            return
        }

        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let localPoint = convert(event.locationInWindow, from: nil)

        // Check if click is in the fold marker area (left side of gutter)
        if localPoint.x < 14 {
            let textViewY = localPoint.y + visibleRect.origin.y
            let adjustedPoint = NSPoint(x: 0, y: textViewY - textView.textContainerInset.height)
            let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            if charIndex < text.length {
                // Find the line number
                let lineNum = Self.countNewlines(in: text, upTo: charIndex)

                if foldableLines.contains(lineNum) {
                    onFoldToggle?(lineNum)
                    return
                }
            }
        }

        // Default: select the line and set anchor for drag
        let textViewY = localPoint.y + visibleRect.origin.y
        let adjustedPoint = NSPoint(x: 0, y: textViewY - textView.textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard charIndex < text.length else { return }

        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        textView.setSelectedRange(lineRange)
        dragAnchorLineRange = lineRange
        window?.makeFirstResponder(textView)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let anchor = dragAnchorLineRange else { return }

        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let localPoint = convert(event.locationInWindow, from: nil)
        let textViewY = localPoint.y + visibleRect.origin.y
        let adjustedPoint = NSPoint(x: 0, y: textViewY - textView.textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = min(layoutManager.characterIndexForGlyph(at: glyphIndex), text.length - 1)

        let dragLineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))

        // Union of anchor line range and current drag line range
        let start = min(anchor.location, dragLineRange.location)
        let end = max(NSMaxRange(anchor), NSMaxRange(dragLineRange))
        textView.setSelectedRange(NSRange(location: start, length: end - start))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorLineRange = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = theme?.gutterBackground ?? NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
        let lineNumColor = theme?.gutterForeground ?? NSColor(white: 0.45, alpha: 1.0)
        let currentColor = theme?.gutterCurrentLine ?? NSColor(white: 0.75, alpha: 1.0)

        bgColor.setFill()
        dirtyRect.fill()

        // Right edge divider line
        NSColor(white: 0.25, alpha: 1.0).setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let text = textView.string as NSString
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let fontSize: CGFloat = 11

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: lineNumColor,
        ]

        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: currentColor,
        ]

        let selectedRange = textView.selectedRange()
        let cursorLineRange = text.lineRange(for: NSRange(location: min(selectedRange.location, text.length), length: 0))

        // Get the visible glyph range
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Count lines before visible range (newline count + 1 = line number)
        var lineNumber = Self.countNewlines(in: text, upTo: min(visibleCharRange.location, text.length)) + 1

        var charIndex = visibleCharRange.location

        while charIndex < NSMaxRange(visibleCharRange) && charIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height
            lineRect.origin.y -= visibleRect.origin.y

            // Current line highlight bar
            let isCurrent = NSLocationInRange(cursorLineRange.location, lineRange)
            if isCurrent, let currentLineBg = theme?.currentLine {
                currentLineBg.setFill()
                NSRect(x: 0, y: lineRect.origin.y, width: bounds.width, height: lineRect.height).fill()
            }

            // Diagnostic marker (red dot)
            let zeroIndexedLine = lineNumber - 1
            if diagnosticLines.contains(zeroIndexedLine) {
                let dotSize: CGFloat = 6
                let dotRect = NSRect(
                    x: 3,
                    y: lineRect.origin.y + (lineRect.height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            // Git change marker (colored bar on left edge)
            if let changeType = changedLines[zeroIndexedLine] {
                let barColor = changeType == "added"
                    ? NSColor(red: 0.30, green: 0.75, blue: 0.30, alpha: 1.0)
                    : NSColor(red: 0.40, green: 0.60, blue: 0.95, alpha: 1.0)
                barColor.setFill()
                NSRect(x: 0, y: lineRect.origin.y, width: 3, height: lineRect.height).fill()
            }

            // Fold marker (triangle)
            if foldableLines.contains(zeroIndexedLine) {
                let isFolded = foldedLines.contains(zeroIndexedLine)
                drawFoldMarker(
                    at: NSPoint(x: 4, y: lineRect.origin.y + (lineRect.height - 8) / 2),
                    isFolded: isFolded,
                    color: isCurrent ? currentColor : lineNumColor,
                )
            }

            let useAttrs = isCurrent ? currentAttrs : attrs
            let numberString = "\(lineNumber)" as NSString
            let stringSize = numberString.size(withAttributes: useAttrs)
            let drawPoint = NSPoint(
                x: bounds.width - stringSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - stringSize.height) / 2
            )
            numberString.draw(at: drawPoint, withAttributes: useAttrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }

    private func drawFoldMarker(at point: NSPoint, isFolded: Bool, color: NSColor) {
        let size: CGFloat = 8
        let path = NSBezierPath()

        if isFolded {
            // Right-pointing triangle ▶
            path.move(to: NSPoint(x: point.x, y: point.y))
            path.line(to: NSPoint(x: point.x + size, y: point.y + size / 2))
            path.line(to: NSPoint(x: point.x, y: point.y + size))
        } else {
            // Down-pointing triangle ▼
            path.move(to: NSPoint(x: point.x, y: point.y + 1))
            path.line(to: NSPoint(x: point.x + size, y: point.y + 1))
            path.line(to: NSPoint(x: point.x + size / 2, y: point.y + size - 1))
        }

        path.close()
        color.withAlphaComponent(0.6).setFill()
        path.fill()
    }
}
