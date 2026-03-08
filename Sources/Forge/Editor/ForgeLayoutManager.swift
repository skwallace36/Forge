import AppKit

/// Custom layout manager that draws indent guides behind the text.
class ForgeLayoutManager: NSLayoutManager {

    var indentGuideColor = NSColor(white: 0.30, alpha: 0.35)
    var tabSpaces: Int = 4

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        if Preferences.shared.showIndentGuides {
            drawIndentGuides(forGlyphRange: glyphsToShow, at: origin)
        }
    }

    private func drawIndentGuides(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              !textContainers.isEmpty else { return }

        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        // Calculate the width of one space in the current font
        let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let spaceWidth = NSAttributedString(
            string: " ",
            attributes: [.font: font]
        ).size().width
        let indentWidth = spaceWidth * CGFloat(tabSpaces)

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        indentGuideColor.setStroke()

        var lineStart = charRange.location
        while lineStart < NSMaxRange(charRange) && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))

            // Count leading whitespace
            var spaces = 0
            let lineEnd = min(NSMaxRange(lineRange), text.length)
            var idx = lineRange.location
            while idx < lineEnd {
                let ch = text.character(at: idx)
                if ch == 0x20 { // space
                    spaces += 1
                } else if ch == 0x09 { // tab
                    spaces += tabSpaces
                } else {
                    break
                }
                idx += 1
            }

            let indentLevels = spaces / tabSpaces

            if indentLevels > 0 {
                // Get the line's visual rect
                let glyphRange = self.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
                    lineStart = NSMaxRange(lineRange)
                    continue
                }

                let lineRect = self.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

                for level in 0..<indentLevels {
                    let x = origin.x + CGFloat(level) * indentWidth + textContainerInset().width
                    let guide = NSBezierPath()
                    guide.move(to: NSPoint(x: x, y: lineRect.origin.y + origin.y))
                    guide.line(to: NSPoint(x: x, y: lineRect.origin.y + lineRect.height + origin.y))
                    guide.lineWidth = 0.5
                    guide.stroke()
                }
            }

            lineStart = NSMaxRange(lineRange)
        }
    }

    private func textContainerInset() -> NSSize {
        guard let tv = firstTextView else { return .zero }
        return tv.textContainerInset
    }
}
