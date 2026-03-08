import AppKit

/// Line number gutter drawn alongside the text view.
class GutterView: NSView {

    weak var textView: NSTextView?
    var theme: Theme?
    var diagnosticLines: Set<Int> = [] // 0-indexed line numbers with diagnostics
    var changedLines: [Int: String] = [:] // 0-indexed: "added" or "modified"

    override var isFlipped: Bool { true }

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

        // Adjust y for scroll offset
        let textViewY = localPoint.y + visibleRect.origin.y

        // Convert to a character index via layout manager
        let adjustedPoint = NSPoint(
            x: 0,
            y: textViewY - textView.textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard charIndex < text.length else { return }

        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        textView.setSelectedRange(lineRange)
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

        // Count lines before visible range
        let preText = text.substring(with: NSRange(location: 0, length: min(visibleCharRange.location, text.length)))
        var lineNumber = preText.components(separatedBy: "\n").count

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
}
