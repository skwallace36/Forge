import AppKit

/// The main editor area: gutter + text view in a scroll view.
class ForgeEditorView: NSView {

    let scrollView = NSScrollView()
    let textView: ForgeTextView
    let gutterView = GutterView()

    private(set) var document: ForgeDocument?
    private var highlighter: SyntaxHighlighter?
    private var rehighlightWorkItem: DispatchWorkItem?
    private var lspChangeWorkItem: DispatchWorkItem?

    /// Set this to enable LSP integration
    weak var lspClient: LSPClient?

    /// Current diagnostics for this document
    private(set) var diagnostics: [LSPDiagnostic] = []

    let theme: Theme = .xcodeDefaultDark
    let fontSize: CGFloat = 13

    override init(frame frameRect: NSRect) {
        textView = ForgeTextView(frame: .zero)
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        textView = ForgeTextView(frame: .zero)
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Configure text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Editor font & colors from theme
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]

        // Text container sizing
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView

        // Gutter
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.theme = theme
        addSubview(gutterView)

        // Layout
        NSLayoutConstraint.activate([
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe text changes for gutter updates and re-highlighting
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe scroll for gutter sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Observe selection changes for current line highlight
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
        textView.isRichText = true
        textView.textStorage?.setAttributedString(doc.textStorage)

        // Re-apply base font/color
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground

        // Syntax highlighting
        if doc.fileExtension == "swift" {
            highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
            highlighter?.parse(doc.textStorage.string)
            if let ts = textView.textStorage {
                highlighter?.highlight(ts)
            }
        } else {
            highlighter = nil
        }

        textView.isRichText = true

        // Apply any existing diagnostics
        applyDiagnosticUnderlines()

        gutterView.textView = textView
        gutterView.needsDisplay = true
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

        // Remove existing underlines first
        ts.beginEditing()
        ts.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: ts.length))
        ts.removeAttribute(.underlineColor, range: NSRange(location: 0, length: ts.length))
        ts.removeAttribute(.toolTip, range: NSRange(location: 0, length: ts.length))

        for diagnostic in diagnostics {
            guard let range = lspRangeToNSRange(diagnostic.range, in: text) else { continue }

            let color: NSColor
            switch diagnostic.severity {
            case 1: color = NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0) // error - red
            case 2: color = NSColor(red: 0.99, green: 0.80, blue: 0.28, alpha: 1.0) // warning - yellow
            default: color = NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0) // info - blue
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

        // Find start position
        while currentLine < lspRange.start.line && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            currentLine += 1
        }
        let startOffset = min(lineStart + lspRange.start.character, text.length)

        // Find end position
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

        // Debounced re-highlight (50ms)
        rehighlightWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rehighlight()
        }
        rehighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)

        // Debounced LSP didChange (100ms)
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
    }

    private func rehighlight() {
        guard let highlighter = highlighter, let ts = textView.textStorage else { return }
        let text = ts.string
        highlighter.parse(text)

        // Preserve selection
        let selectedRange = textView.selectedRange()
        highlighter.highlight(ts)

        // Re-apply diagnostics on top of highlighting
        applyDiagnosticUnderlines()

        textView.setSelectedRange(selectedRange)
    }

    private func notifyLSPChange() {
        guard let doc = document, let ts = textView.textStorage else { return }
        lspClient?.didChange(url: doc.url, text: ts.string)
    }
}
