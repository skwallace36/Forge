import AppKit

/// A minimap (code overview) that renders a scaled-down version of the code.
/// Appears on the right side of the editor and allows quick scrolling.
class MinimapView: NSView {

    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    /// Diagnostic markers: (line: 0-indexed, severity: 1=error, 2=warning)
    var diagnosticMarkers: [(line: Int, severity: Int)] = [] {
        didSet { cachedCodeImage = nil }
    }

    /// Search match positions (character offsets) shown as orange markers
    var searchMatchRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }

    /// Bookmarked line numbers (0-indexed), shown as blue markers
    var bookmarkedLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// Current cursor character offset for cursor position marker
    var currentCursorOffset: Int = 0 {
        didSet { if oldValue != currentCursorOffset { needsDisplay = true } }
    }

    private let scale: CGFloat = 0.12
    private let minimapWidth: CGFloat = 80

    private let bgColor = NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
    private let viewportColor = NSColor(white: 0.5, alpha: 0.15)
    private let viewportBorderColor = NSColor(white: 0.5, alpha: 0.25)

    /// Cached rendering of code lines — invalidated when text changes
    private var cachedCodeImage: NSImage?
    /// Text length when cache was built — used to detect changes
    private var cachedTextLength: Int = -1
    /// Bounds size when cache was built
    private var cachedBoundsSize: NSSize = .zero
    /// Scale factor used when cache was built
    private var cachedScaleFactor: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        observePreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func observePreferences() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .preferencesDidChange,
            object: nil,
        )
    }

    @objc private func preferencesDidChange() {
        invalidateCodeCache()
    }

    /// Call this when text content changes to invalidate the cached minimap
    func invalidateCodeCache() {
        cachedCodeImage = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        bounds.fill()

        // Left edge divider
        NSColor(white: 0.25, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        let text = textView.string as NSString
        guard text.length > 0 else { return }

        // Calculate total text height
        layoutManager.ensureLayout(for: textContainer)
        let totalTextHeight = layoutManager.usedRect(for: textContainer).height

        // Scale factor to fit the text into the minimap
        let scaleFactor = min(scale, bounds.height / max(totalTextHeight, 1))

        // Check if we need to rebuild the code cache
        let needsRebuild = cachedCodeImage == nil
            || cachedTextLength != text.length
            || cachedBoundsSize != bounds.size
            || cachedScaleFactor != scaleFactor

        if needsRebuild {
            cachedCodeImage = renderCodeImage(
                text: text,
                layoutManager: layoutManager,
                textContainer: textContainer,
                textView: textView,
                scaleFactor: scaleFactor,
            )
            cachedTextLength = text.length
            cachedBoundsSize = bounds.size
            cachedScaleFactor = scaleFactor
        }

        // Draw the cached code image
        if let image = cachedCodeImage {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Draw viewport rectangle (changes on every scroll, so not cached)
        let visibleRect = scrollView.contentView.bounds
        let viewportY = (visibleRect.origin.y) * scaleFactor
        let viewportHeight = visibleRect.height * scaleFactor

        viewportColor.setFill()
        let vpRect = NSRect(x: 1, y: viewportY, width: bounds.width - 1, height: viewportHeight)
        vpRect.fill()

        viewportBorderColor.setStroke()
        NSBezierPath(rect: vpRect).stroke()

        // Draw current cursor line marker
        if currentCursorOffset >= 0 && currentCursorOffset < text.length {
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: currentCursorOffset)
            if glyphIdx != NSNotFound {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                let y = (lineRect.origin.y + textView.textContainerInset.height) * scaleFactor
                NSColor(white: 0.85, alpha: 0.70).setFill()
                NSRect(x: 1, y: y, width: bounds.width - 2, height: max(1.5, lineRect.height * scaleFactor)).fill()
            }
        }

        // Draw search match markers on the right edge
        if !searchMatchRanges.isEmpty {
            let searchColor = NSColor(red: 0.95, green: 0.70, blue: 0.20, alpha: 0.80)
            searchColor.setFill()
            for range in searchMatchRanges {
                guard range.location < text.length else { continue }
                let glyphIdx = layoutManager.glyphIndexForCharacter(at: range.location)
                guard glyphIdx != NSNotFound else { continue }
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                let y = (lineRect.origin.y + textView.textContainerInset.height) * scaleFactor
                NSRect(x: bounds.width - 8, y: y, width: 7, height: max(2, 2)).fill()
            }
        }

        // Draw bookmark markers on the right edge (blue)
        if !bookmarkedLines.isEmpty {
            let bookmarkColor = NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.85)
            bookmarkColor.setFill()
            // Build line offsets for bookmark positions
            var lineOffsets = [0]
            let maxBookmarkLine = bookmarkedLines.max() ?? 0
            for i in 0..<text.length where lineOffsets.count <= maxBookmarkLine {
                if text.character(at: i) == 0x0A {
                    lineOffsets.append(i + 1)
                }
            }
            for line in bookmarkedLines {
                guard line < lineOffsets.count else { continue }
                let charIdx = lineOffsets[line]
                guard charIdx < text.length else { continue }
                let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIdx)
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                let y = (lineRect.origin.y + textView.textContainerInset.height) * scaleFactor
                NSRect(x: bounds.width - 8, y: y, width: 7, height: max(2, 3)).fill()
            }
        }
    }

    private func renderCodeImage(
        text: NSString,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        textView: NSTextView,
        scaleFactor: CGFloat
    ) -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(true)

        // Draw simplified code blocks as thin lines
        var charIndex = 0
        while charIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

            guard glyphRange.length > 0 else {
                charIndex = NSMaxRange(lineRange)
                continue
            }

            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let y = (lineRect.origin.y + textView.textContainerInset.height) * scaleFactor
            let height = max(1, lineRect.height * scaleFactor)

            // Get the line text to determine width and color
            let lineText = text.substring(with: lineRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                charIndex = NSMaxRange(lineRange)
                continue
            }

            let leadingSpaces = lineText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let contentLength = trimmed.count
            let xOffset = CGFloat(leadingSpaces) * 2.5 * scaleFactor + 6
            let lineWidth = min(CGFloat(contentLength) * 2.5 * scaleFactor, bounds.width - xOffset - 4)

            // Sample the dominant foreground color from the line's text storage
            let lineColor: NSColor
            if let ts = textView.textStorage {
                // Sample color from the first non-whitespace character of the line
                let firstNonWS = lineRange.location + leadingSpaces
                if firstNonWS < NSMaxRange(lineRange) && firstNonWS < ts.length {
                    let fg = ts.attribute(.foregroundColor, at: firstNonWS, effectiveRange: nil) as? NSColor
                    lineColor = (fg ?? NSColor.white).withAlphaComponent(0.45)
                } else {
                    lineColor = NSColor(white: 0.55, alpha: 0.4)
                }
            } else {
                lineColor = NSColor(white: 0.55, alpha: 0.4)
            }

            lineColor.setFill()
            NSRect(x: xOffset, y: y, width: lineWidth, height: max(1, height * 0.6)).fill()

            charIndex = NSMaxRange(lineRange)
        }

        // Draw diagnostic markers on the right edge (part of the static content)
        if !diagnosticMarkers.isEmpty {
            // Build line offsets once for all markers
            let maxLine = diagnosticMarkers.max(by: { $0.line < $1.line })?.line ?? 0
            var lineOffsets = [0]
            for i in 0..<text.length where lineOffsets.count <= maxLine {
                if text.character(at: i) == 0x0A {
                    lineOffsets.append(i + 1)
                }
            }

            for marker in diagnosticMarkers {
                let markerColor: NSColor = marker.severity == 1
                    ? NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 0.85)
                    : NSColor(red: 0.99, green: 0.80, blue: 0.28, alpha: 0.85)

                let charIdx = marker.line < lineOffsets.count ? lineOffsets[marker.line] : min(text.length - 1, 0)
                guard charIdx >= 0 && charIdx < text.length else { continue }

                let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIdx)
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                let lineY = (lineRect.origin.y + textView.textContainerInset.height) * scaleFactor

                markerColor.setFill()
                NSRect(x: bounds.width - 4, y: lineY, width: 3, height: max(2, 3 / scaleFactor)).fill()
            }
        }

        image.unlockFocus()
        return image
    }


    // MARK: - Click to scroll

    override func mouseDown(with event: NSEvent) {
        scrollToPosition(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrollToPosition(for: event)
    }

    private func scrollToPosition(for event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let totalHeight = layoutManager.usedRect(for: textContainer).height
        let scaleFactor = min(scale, bounds.height / max(totalHeight, 1))

        // Convert minimap Y to text view Y
        let textY = localPoint.y / scaleFactor
        let visibleHeight = scrollView.contentView.bounds.height

        // Center the viewport on the click position
        let scrollY = max(0, textY - visibleHeight / 2)

        // Animate scroll for click, immediate for drag
        if event.type == .leftMouseDown {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: scrollY))
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            var newOrigin = scrollView.contentView.bounds.origin
            newOrigin.y = scrollY
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
