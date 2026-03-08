import AppKit

/// Custom layout manager that draws indent guides behind the text.
class ForgeLayoutManager: NSLayoutManager {

    var indentGuideColor = NSColor(white: 0.30, alpha: 0.35)
    var columnRulerColor = NSColor(white: 0.22, alpha: 1.0)
    var invisibleColor = NSColor(white: 0.35, alpha: 0.5)
    var tabSpaces: Int = 4
    var rulerColumn: Int = 0 // 0 = disabled

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        if Preferences.shared.showIndentGuides {
            drawIndentGuides(forGlyphRange: glyphsToShow, at: origin)
        }
        if rulerColumn > 0 {
            drawColumnRuler(forGlyphRange: glyphsToShow, at: origin)
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

    private func drawColumnRuler(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              let tv = firstTextView else { return }

        let font = textStorage.length > 0
            ? textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let spaceWidth = NSAttributedString(
            string: " ",
            attributes: [.font: font]
        ).size().width

        let x = origin.x + CGFloat(rulerColumn) * spaceWidth + tv.textContainerInset.width
        let visibleRect = tv.enclosingScrollView?.contentView.bounds ?? tv.bounds

        columnRulerColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: visibleRect.origin.y))
        path.line(to: NSPoint(x: x, y: visibleRect.origin.y + visibleRect.height))
        path.lineWidth = 1.0
        path.stroke()
    }

    private func textContainerInset() -> NSSize {
        guard let tv = firstTextView else { return .zero }
        return tv.textContainerInset
    }

    // MARK: - Invisible Characters

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        guard Preferences.shared.showInvisibles else { return }
        drawInvisibles(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawInvisibles(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              let tc = textContainers.first else { return }

        let text = textStorage.string as NSString
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let inset = textContainerInset()

        let font = textStorage.length > 0
            ? textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let spaceAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: invisibleColor,
        ]

        let dotStr = "\u{00B7}" as NSString    // middle dot for spaces
        let arrowStr = "\u{2192}" as NSString  // right arrow for tabs
        let returnStr = "\u{00AC}" as NSString // not sign for newlines

        for charIdx in charRange.location..<min(NSMaxRange(charRange), text.length) {
            let ch = text.character(at: charIdx)
            let drawStr: NSString?

            switch ch {
            case 0x20: // space
                drawStr = dotStr
            case 0x09: // tab
                drawStr = arrowStr
            case 0x0A: // newline
                drawStr = returnStr
            default:
                continue
            }

            guard let str = drawStr else { continue }

            let glyphIdx = glyphIndexForCharacter(at: charIdx)
            guard glyphIdx != NSNotFound else { continue }

            let lineRect = lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let glyphLocation = location(forGlyphAt: glyphIdx)

            let point = NSPoint(
                x: origin.x + lineRect.origin.x + glyphLocation.x + inset.width,
                y: origin.y + lineRect.origin.y + inset.height,
            )
            str.draw(at: point, withAttributes: spaceAttrs)
        }
    }
}
