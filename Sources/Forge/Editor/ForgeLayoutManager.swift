import AppKit

/// Custom layout manager that draws indent guides behind the text.
class ForgeLayoutManager: NSLayoutManager {

    var indentGuideColor = NSColor(white: 0.30, alpha: 0.35)
    var activeIndentGuideColor = NSColor(white: 0.55, alpha: 0.60)
    var columnRulerColor = NSColor(white: 0.22, alpha: 1.0)
    var invisibleColor = NSColor(white: 0.35, alpha: 0.5)
    var tabSpaces: Int = 4
    var rulerColumn: Int = 0 // 0 = disabled

    /// The indent level of the line the cursor is on (0-based). -1 means no active guide.
    var activeIndentLevel: Int = -1

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

        let activeLevel = activeIndentLevel

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
                    // Highlight the active indent guide
                    if level == activeLevel {
                        activeIndentGuideColor.setStroke()
                    } else {
                        indentGuideColor.setStroke()
                    }
                    let guide = NSBezierPath()
                    guide.move(to: NSPoint(x: x, y: lineRect.origin.y + origin.y))
                    guide.line(to: NSPoint(x: x, y: lineRect.origin.y + lineRect.height + origin.y))
                    guide.lineWidth = level == activeLevel ? 1.0 : 0.5
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

        drawColorSwatches(forGlyphRange: glyphsToShow, at: origin)
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

    // MARK: - Color Swatches

    /// Regex matching hex color literals: #RGB, #RRGGBB, #RRGGBBAA, 0xRRGGBB
    private static let hexColorRegex = try! NSRegularExpression(
        pattern: #"(?:#|0x)([0-9A-Fa-f]{3,8})\b"#
    )

    /// Regex matching NSColor/UIColor(red:green:blue:alpha:)
    private static let rgbaColorRegex = try! NSRegularExpression(
        pattern: #"(?:NS|UI)Color\(\s*red:\s*([\d.]+)\s*,\s*green:\s*([\d.]+)\s*,\s*blue:\s*([\d.]+)\s*,\s*alpha:\s*([\d.]+)\s*\)"#
    )

    /// Regex matching NSColor/UIColor(white:alpha:)
    private static let whiteColorRegex = try! NSRegularExpression(
        pattern: #"(?:NS|UI)Color\(\s*white:\s*([\d.]+)\s*,\s*alpha:\s*([\d.]+)\s*\)"#
    )

    /// Regex matching Color(.sRGB, red:green:blue:opacity:) (SwiftUI)
    private static let swiftUIColorRegex = try! NSRegularExpression(
        pattern: #"Color\([^)]*red:\s*([\d.]+)\s*,\s*green:\s*([\d.]+)\s*,\s*blue:\s*([\d.]+)"#
    )

    private func drawColorSwatches(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage = textStorage,
              !textContainers.isEmpty else { return }

        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let inset = textContainerInset()
        let visibleString = text.substring(with: charRange)
        let nsVisible = visibleString as NSString
        let baseOffset = charRange.location

        // Collect color matches from all patterns
        var colorMatches: [(range: NSRange, color: NSColor)] = []

        // Hex colors
        let hexMatches = Self.hexColorRegex.matches(in: visibleString, range: NSRange(location: 0, length: nsVisible.length))
        for match in hexMatches {
            guard match.numberOfRanges >= 2 else { continue }
            let hexStr = nsVisible.substring(with: match.range(at: 1))
            if let color = Self.colorFromHex(hexStr) {
                colorMatches.append((NSRange(location: match.range.location + baseOffset, length: match.range.length), color))
            }
        }

        // RGBA colors
        let rgbaMatches = Self.rgbaColorRegex.matches(in: visibleString, range: NSRange(location: 0, length: nsVisible.length))
        for match in rgbaMatches {
            guard match.numberOfRanges >= 5,
                  let r = Double(nsVisible.substring(with: match.range(at: 1))),
                  let g = Double(nsVisible.substring(with: match.range(at: 2))),
                  let b = Double(nsVisible.substring(with: match.range(at: 3))),
                  let a = Double(nsVisible.substring(with: match.range(at: 4))) else { continue }
            let color = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
            colorMatches.append((NSRange(location: match.range.location + baseOffset, length: match.range.length), color))
        }

        // White colors
        let whiteMatches = Self.whiteColorRegex.matches(in: visibleString, range: NSRange(location: 0, length: nsVisible.length))
        for match in whiteMatches {
            guard match.numberOfRanges >= 3,
                  let w = Double(nsVisible.substring(with: match.range(at: 1))),
                  let a = Double(nsVisible.substring(with: match.range(at: 2))) else { continue }
            let color = NSColor(white: CGFloat(w), alpha: CGFloat(a))
            colorMatches.append((NSRange(location: match.range.location + baseOffset, length: match.range.length), color))
        }

        // SwiftUI Color
        let swiftUIMatches = Self.swiftUIColorRegex.matches(in: visibleString, range: NSRange(location: 0, length: nsVisible.length))
        for match in swiftUIMatches {
            guard match.numberOfRanges >= 4,
                  let r = Double(nsVisible.substring(with: match.range(at: 1))),
                  let g = Double(nsVisible.substring(with: match.range(at: 2))),
                  let b = Double(nsVisible.substring(with: match.range(at: 3))) else { continue }
            let color = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
            colorMatches.append((NSRange(location: match.range.location + baseOffset, length: match.range.length), color))
        }

        // Draw swatches
        for (range, color) in colorMatches {
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { continue }

            let lineRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let glyphLoc = location(forGlyphAt: glyphRange.location)

            let swatchSize: CGFloat = 10
            let x = origin.x + lineRect.origin.x + glyphLoc.x + inset.width - swatchSize - 3
            let y = origin.y + lineRect.origin.y + inset.height + (lineRect.height - swatchSize) / 2

            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)

            // Draw checkerboard background (to show alpha)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()

            // Draw the color
            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()

            // Border
            NSColor(white: 0.5, alpha: 0.5).setStroke()
            let borderPath = NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2)
            borderPath.lineWidth = 0.5
            borderPath.stroke()
        }
    }

    private static func colorFromHex(_ hex: String) -> NSColor? {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1.0

        switch cleanHex.count {
        case 3: // RGB
            guard let val = UInt32(cleanHex, radix: 16) else { return nil }
            r = CGFloat((val >> 8) & 0xF) / 15.0
            g = CGFloat((val >> 4) & 0xF) / 15.0
            b = CGFloat(val & 0xF) / 15.0
        case 6: // RRGGBB
            guard let val = UInt32(cleanHex, radix: 16) else { return nil }
            r = CGFloat((val >> 16) & 0xFF) / 255.0
            g = CGFloat((val >> 8) & 0xFF) / 255.0
            b = CGFloat(val & 0xFF) / 255.0
        case 8: // RRGGBBAA
            guard let val = UInt32(cleanHex, radix: 16) else { return nil }
            r = CGFloat((val >> 24) & 0xFF) / 255.0
            g = CGFloat((val >> 16) & 0xFF) / 255.0
            b = CGFloat((val >> 8) & 0xFF) / 255.0
            a = CGFloat(val & 0xFF) / 255.0
        default:
            return nil
        }

        return NSColor(red: r, green: g, blue: b, alpha: a)
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
