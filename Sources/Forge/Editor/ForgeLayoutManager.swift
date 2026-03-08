import AppKit

/// Custom layout manager that draws indent guides behind the text.
class ForgeLayoutManager: NSLayoutManager {

    var indentGuideColor = NSColor(white: 0.30, alpha: 0.35)
    var columnRulerColor = NSColor(white: 0.22, alpha: 1.0)
    var invisibleColor = NSColor(white: 0.35, alpha: 0.5)
    var tabSpaces: Int = 4
    var rulerColumn: Int = 0 // 0 = disabled

    /// Inline diagnostic messages: maps 0-indexed line number to (message, severity)
    /// Severity: 1 = error, 2 = warning, 3+ = info/hint
    var inlineDiagnostics: [Int: (message: String, severity: Int)] = [:]

    /// Cached space width for the current font — avoids creating an NSAttributedString per draw
    private var cachedSpaceWidth: CGFloat = 0
    private var cachedSpaceFont: NSFont?

    private func spaceWidth(for font: NSFont) -> CGFloat {
        if font === cachedSpaceFont || font == cachedSpaceFont {
            return cachedSpaceWidth
        }
        cachedSpaceFont = font
        cachedSpaceWidth = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        return cachedSpaceWidth
    }

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

        // Calculate the width of one space in the current font (cached)
        let font = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let sw = spaceWidth(for: font)
        let indentWidth = sw * CGFloat(tabSpaces)

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

        let x = origin.x + CGFloat(rulerColumn) * spaceWidth(for: font) + tv.textContainerInset.width
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

        if Preferences.shared.showInvisibles {
            drawInvisibles(forGlyphRange: glyphsToShow, at: origin)
        }

        if !inlineDiagnostics.isEmpty {
            drawInlineDiagnostics(forGlyphRange: glyphsToShow, at: origin)
        }
    }

    // MARK: - Inline Diagnostics

    private static let errorBgColor = NSColor(red: 0.50, green: 0.10, blue: 0.10, alpha: 0.45)
    private static let errorTextColor = NSColor(red: 1.0, green: 0.65, blue: 0.65, alpha: 1.0)
    private static let warningBgColor = NSColor(red: 0.45, green: 0.35, blue: 0.08, alpha: 0.45)
    private static let warningTextColor = NSColor(red: 1.0, green: 0.90, blue: 0.55, alpha: 1.0)
    private static let infoBgColor = NSColor(red: 0.15, green: 0.25, blue: 0.40, alpha: 0.45)
    private static let infoTextColor = NSColor(red: 0.70, green: 0.85, blue: 1.0, alpha: 1.0)

    private func drawInlineDiagnostics(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              !textContainers.isEmpty else { return }

        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let inset = textContainerInset()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Iterate visible lines and draw any diagnostics
        var lineStart = charRange.location
        var lineNum = 0

        // Count lines up to charRange.location
        if lineStart > 0 {
            let prefix = text.substring(to: lineStart)
            lineNum = prefix.components(separatedBy: "\n").count - 1
        }

        while lineStart < NSMaxRange(charRange) && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))

            if let diag = inlineDiagnostics[lineNum] {
                let glyphRange = self.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
                    lineStart = NSMaxRange(lineRange)
                    lineNum += 1
                    continue
                }

                let lineRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let usedRect = lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

                let bgColor: NSColor
                let textColor: NSColor
                let icon: String
                switch diag.severity {
                case 1:
                    bgColor = Self.errorBgColor
                    textColor = Self.errorTextColor
                    icon = "⛔ "
                case 2:
                    bgColor = Self.warningBgColor
                    textColor = Self.warningTextColor
                    icon = "⚠️ "
                default:
                    bgColor = Self.infoBgColor
                    textColor = Self.infoTextColor
                    icon = "ℹ️ "
                }

                // Truncate to first line of the message
                let msg = diag.message.components(separatedBy: "\n").first ?? diag.message
                let displayMsg = icon + msg
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                let msgSize = (displayMsg as NSString).size(withAttributes: attrs)

                // Position: after the used line content, with some padding
                let xStart = origin.x + usedRect.maxX + inset.width + 16
                let yPos = origin.y + lineRect.origin.y + inset.height

                // Background rounded rect
                let padding: CGFloat = 4
                let bgRect = NSRect(
                    x: xStart - padding,
                    y: yPos + (lineRect.height - msgSize.height) / 2 - 1,
                    width: msgSize.width + padding * 2,
                    height: msgSize.height + 2,
                )
                let path = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
                bgColor.setFill()
                path.fill()

                // Draw message text
                let textPoint = NSPoint(
                    x: xStart,
                    y: yPos + (lineRect.height - msgSize.height) / 2,
                )
                (displayMsg as NSString).draw(at: textPoint, withAttributes: attrs)
            }

            lineStart = NSMaxRange(lineRange)
            lineNum += 1
        }
    }

    private func drawInvisibles(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              !textContainers.isEmpty else { return }

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
