import AppKit

/// Line number gutter drawn alongside the text view.
class GutterView: NSView {

    weak var textView: NSTextView?
    var theme: Theme?
    var diagnosticLines: Set<Int> = [] // 0-indexed line numbers with diagnostics

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = theme?.gutterBackground ?? NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
        let lineNumColor = theme?.gutterForeground ?? NSColor(white: 0.45, alpha: 1.0)
        let currentColor = theme?.gutterCurrentLine ?? NSColor(white: 0.75, alpha: 1.0)

        bgColor.setFill()
        dirtyRect.fill()

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
