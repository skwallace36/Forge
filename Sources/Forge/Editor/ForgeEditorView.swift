import AppKit

/// Manages the editor text view, gutter, syntax highlighting, and LSP integration.
/// This is NOT a view subclass — it manages views that are added to a parent container.
class ForgeEditorManager {

    let scrollView: NSScrollView
    let textView: NSTextView
    let gutterView = GutterView()

    private(set) var document: ForgeDocument?
    private var highlighter: SyntaxHighlighter?
    private var rehighlightWorkItem: DispatchWorkItem?
    private var lspChangeWorkItem: DispatchWorkItem?

    /// Set this to enable LSP integration
    weak var lspClient: LSPClient?

    /// Current diagnostics for this document
    private(set) var diagnostics: [LSPDiagnostic] = []

    /// Called when cursor position changes: (line, column, totalLines)
    var onCursorChange: ((Int, Int, Int) -> Void)?

    let theme: Theme = .xcodeDefaultDark
    let fontSize: CGFloat = 13
    let gutterWidth: CGFloat = 44

    init() {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView

        self.scrollView = sv
        self.textView = tv

        configureTextView()
        configureGutter()
        registerObservers()
    }

    private func configureTextView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Disable line wrapping — scroll horizontally
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Editor font & colors from theme
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]

        // Small left padding for text (gutter is beside the scroll view, not overlaying)
        textView.textContainerInset = NSSize(width: 4, height: 0)
    }

    private func configureGutter() {
        gutterView.theme = theme
    }

    private func registerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
    }

    func displayDocument(_ doc: ForgeDocument) {
        self.document = doc

        // Set text content
        textView.string = doc.textStorage.string

        // Apply font and foreground color
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground

        if let ts = textView.textStorage, ts.length > 0 {
            let fullRange = NSRange(location: 0, length: ts.length)
            ts.beginEditing()
            ts.addAttributes([
                .foregroundColor: theme.foreground,
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            ], range: fullRange)
            ts.endEditing()
        }

        // Syntax highlighting
        if doc.fileExtension == "swift" {
            highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
            highlighter?.parse(textView.string)
            if let ts = textView.textStorage {
                highlighter?.highlight(ts)
            }
        } else {
            highlighter = nil
        }

        // Apply any existing diagnostics
        applyDiagnosticUnderlines()

        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

        gutterView.textView = textView
        gutterView.needsDisplay = true

        // Fire initial cursor position
        notifyCursorPosition()
    }

    // MARK: - Diagnostics

    func updateDiagnostics(_ newDiagnostics: [LSPDiagnostic]) {
        self.diagnostics = newDiagnostics
        applyDiagnosticUnderlines()
        gutterView.diagnosticLines = diagnosticLineNumbers()
        gutterView.needsDisplay = true
    }

    private func applyDiagnosticUnderlines() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString

        ts.beginEditing()
        ts.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: ts.length))
        ts.removeAttribute(.underlineColor, range: NSRange(location: 0, length: ts.length))
        ts.removeAttribute(.toolTip, range: NSRange(location: 0, length: ts.length))

        for diagnostic in diagnostics {
            guard let range = lspRangeToNSRange(diagnostic.range, in: text) else { continue }

            let color: NSColor
            switch diagnostic.severity {
            case 1: color = NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0)
            case 2: color = NSColor(red: 0.99, green: 0.80, blue: 0.28, alpha: 1.0)
            default: color = NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0)
            }

            ts.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: color,
                .toolTip: diagnostic.message,
            ], range: range)
        }

        ts.endEditing()
    }

    private func diagnosticLineNumbers() -> Set<Int> {
        var lines = Set<Int>()
        for d in diagnostics {
            lines.insert(d.range.start.line)
        }
        return lines
    }

    private func lspRangeToNSRange(_ lspRange: LSPRange, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }

        var lineStart = 0
        var currentLine = 0

        while currentLine < lspRange.start.line && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            currentLine += 1
        }
        let startOffset = min(lineStart + lspRange.start.character, text.length)

        var endLineStart = lineStart
        while currentLine < lspRange.end.line && endLineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: endLineStart, length: 0))
            endLineStart = NSMaxRange(lineRange)
            currentLine += 1
        }
        let endOffset = min(endLineStart + lspRange.end.character, text.length)

        guard startOffset <= endOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    // MARK: - Text Change Handling

    @objc private func textDidChange(_ notification: Notification) {
        document?.isModified = true
        gutterView.needsDisplay = true

        rehighlightWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rehighlight()
        }
        rehighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)

        lspChangeWorkItem?.cancel()
        let lspWork = DispatchWorkItem { [weak self] in
            self?.notifyLSPChange()
        }
        lspChangeWorkItem = lspWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: lspWork)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        gutterView.needsDisplay = true
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        gutterView.needsDisplay = true
        notifyCursorPosition()
    }

    private func notifyCursorPosition() {
        let text = textView.string as NSString
        let loc = min(textView.selectedRange().location, text.length)

        // Count line and column
        var line = 1
        var lastLineStart = 0
        for i in 0..<loc {
            if text.character(at: i) == 0x0A { // \n
                line += 1
                lastLineStart = i + 1
            }
        }
        let column = loc - lastLineStart + 1
        let totalLines = text.components(separatedBy: "\n").count

        onCursorChange?(line, column, totalLines)
    }

    private func rehighlight() {
        guard let highlighter = highlighter, let ts = textView.textStorage else { return }
        let text = ts.string
        highlighter.parse(text)

        let selectedRange = textView.selectedRange()
        highlighter.highlight(ts)
        applyDiagnosticUnderlines()
        textView.setSelectedRange(selectedRange)
    }

    private func notifyLSPChange() {
        guard let doc = document, let ts = textView.textStorage else { return }
        lspClient?.didChange(url: doc.url, text: ts.string)
    }
}
