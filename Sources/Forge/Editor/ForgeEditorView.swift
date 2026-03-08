import AppKit

/// Manages the editor text view, gutter, syntax highlighting, and LSP integration.
/// This is NOT a view subclass — it manages views that are added to a parent container.
class ForgeEditorManager: NSObject, NSTextViewDelegate, NSMenuDelegate {

    let scrollView: NSScrollView
    let textView: NSTextView
    let gutterView = GutterView()

    private(set) var document: ForgeDocument?
    private var highlighter: SyntaxHighlighter?
    private var simpleHighlighter: SimpleHighlighter?
    private var rehighlightWorkItem: DispatchWorkItem?
    private var lspChangeWorkItem: DispatchWorkItem?

    /// Set this to enable LSP integration
    weak var lspClient: LSPClient?

    /// Current diagnostics for this document
    private(set) var diagnostics: [LSPDiagnostic] = []

    /// Called when cursor position changes: (line, column, totalLines, selectionLength)
    var onCursorChange: ((Int, Int, Int, Int) -> Void)?

    /// Minimap view (set externally, updated on scroll/edit)
    weak var minimapView: MinimapView?

    /// Called when user ⌘-clicks to jump to definition: (url, line, column)
    var onJumpToDefinition: ((URL, Int, Int) -> Void)?

    /// Called when LSP rename produces edits for external files: (url, edits)
    var onApplyEdits: ((URL, [LSPTextEdit]) -> Void)?

    /// Called when "Find All References" finds results: [(url, line, column)]
    var onShowReferences: (([LSPLocation]) -> Void)?

    /// Called when user wants to send selected code to Claude: (code, fileName, line)
    var onSendToClaude: ((String, String?, Int?) -> Void)?

    /// Project root URL for computing relative paths
    var projectRootURL: URL?

    /// Called when text content changes (for promoting preview tabs, etc.)
    var onTextDidChange: (() -> Void)?

    let theme: Theme = .xcodeDefaultDark
    private(set) var fontSize: CGFloat = Preferences.shared.fontSize
    var editorFont: NSFont { Preferences.shared.editorFont(size: fontSize) }
    /// Minimum gutter width; increases for files with 10k+ lines
    private(set) var gutterWidth: CGFloat = 44

    /// Callback to notify container that gutter width needs updating
    var onGutterWidthChange: ((CGFloat) -> Void)?
    var tabWidth: Int { document?.detectedTabWidth ?? Preferences.shared.tabWidth }
    private var forgeLayoutManager: ForgeLayoutManager?

    /// Tracks the previously highlighted line range so we can clear it
    private var currentLineRange: NSRange?

    /// Tracks occurrence highlight ranges so we can clear them
    private var occurrenceHighlightRanges: [NSRange] = []

    /// Tracks bracket match highlight range
    private var bracketMatchRange: NSRange?

    /// Line-start offset cache for O(log n) line/column conversion.
    /// Each entry is the character offset where that line begins.
    /// Invalidated on text change, rebuilt lazily on first access.
    private var _lineStartOffsets: [Int]?

    /// Debounce for occurrence highlighting
    private var occurrenceWorkItem: DispatchWorkItem?

    /// Completion popup
    private var completionWindow: CompletionWindow?

    /// Signature help popover
    private var signaturePopover: NSPopover?
    private var signatureHelpWorkItem: DispatchWorkItem?

    /// Event monitor for ⌘-click and ⌥-click
    private var clickMonitor: Any?

    /// Hover popup
    private var hoverPopover: NSPopover?

    /// Tracks whether completion was auto-triggered (vs explicit ⌃Space)
    private var completionPrefix: String = ""

    override init() {
        // Build the text system manually so we can use a custom layout manager
        let textStorage = NSTextStorage()
        let layoutManager = ForgeLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.addTextContainer(textContainer)

        let tv = ForgeTextView(frame: .zero, textContainer: textContainer)
        let sv = NSScrollView()
        sv.documentView = tv
        tv.autoresizingMask = [.width, .height]

        self.scrollView = sv
        self.textView = tv
        self.forgeLayoutManager = layoutManager

        super.init()

        textView.delegate = self
        configureTextView()
        configureGutter()
        configureContextMenu()
        registerObservers()
        setupClickMonitor()
    }

    deinit {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        completionWindow?.dismiss()
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

        // Apply word wrap setting
        applyWordWrap(Preferences.shared.wordWrap)

        // Editor font & colors from theme
        textView.font = editorFont
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]

        // Small left padding for text (gutter is beside the scroll view, not overlaying)
        textView.textContainerInset = NSSize(width: 4, height: 0)

        // Allow scrolling past end of file so the last line isn't stuck at the bottom
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 200, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        // Configure indent guides and column ruler
        forgeLayoutManager?.tabSpaces = tabWidth
        forgeLayoutManager?.rulerColumn = Preferences.shared.columnRuler
    }

    func applyWordWrap(_ wrap: Bool) {
        if wrap {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
    }

    private func configureGutter() {
        gutterView.theme = theme
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        textView.menu = menu
    }

    private var keyMonitor: Any?

    private func registerObservers() {
        // Text change and selection change are handled via NSTextViewDelegate.
        // Only register for scroll view bounds changes (not a delegate method).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Respond to preferences changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange(_:)),
            name: .preferencesDidChange,
            object: nil
        )

        // Monitor key events for ⌃Space and completion navigation
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  self.textView.window?.firstResponder === self.textView else {
                return event
            }
            if self.handleKeyForCompletion(event) {
                return nil // consume
            }
            return event
        }
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        let prefs = Preferences.shared
        fontSize = prefs.fontSize
        textView.font = editorFont
        applyWordWrap(prefs.wordWrap)
        forgeLayoutManager?.tabSpaces = prefs.tabWidth
        forgeLayoutManager?.rulerColumn = prefs.columnRuler

        // Re-highlight with updated font
        rehighlight()
        gutterView.needsDisplay = true
        textView.needsDisplay = true
    }

    func displayDocument(_ doc: ForgeDocument) {
        // Save state for the previous document
        if let prevDoc = document {
            prevDoc.savedSelectionRange = textView.selectedRange()
            prevDoc.savedScrollPosition = scrollView.contentView.bounds.origin
        }

        self.document = doc

        // Handle binary files
        if doc.isBinary {
            textView.string = ""
            textView.isEditable = false
            highlighter = nil
            simpleHighlighter = nil
            gutterView.textView = textView
            gutterView.needsDisplay = true
            return
        }

        textView.isEditable = true

        // Check if file changed on disk
        if doc.hasChangedOnDisk() {
            if doc.isModified {
                // File modified both in editor and on disk — ask user
                let alert = NSAlert()
                alert.messageText = "\(doc.fileName) has been modified externally."
                alert.informativeText = "Do you want to reload from disk? Your unsaved changes will be lost."
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Keep Mine")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn {
                    doc.loadFromDisk()
                }
            } else {
                // No local changes — silently reload
                doc.loadFromDisk()
            }
        }

        // Set text content
        textView.string = doc.textStorage.string
        invalidateLineCache()
        updateLineCount()
        minimapView?.invalidateCodeCache()

        // Apply font and foreground color
        textView.font = editorFont
        textView.textColor = theme.foreground

        if let ts = textView.textStorage, ts.length > 0 {
            let fullRange = NSRange(location: 0, length: ts.length)
            ts.beginEditing()
            ts.addAttributes([
                .foregroundColor: theme.foreground,
                .font: editorFont,
            ], range: fullRange)
            ts.endEditing()
        }

        // Syntax highlighting — skip for large files (> 1MB) for performance
        let ext = doc.fileExtension.lowercased()
        let isLargeFile = doc.fileSize > 1_000_000

        if isLargeFile {
            highlighter = nil
            simpleHighlighter = nil
        } else if ext == "swift" {
            highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
            simpleHighlighter = nil
            highlighter?.parse(textView.string)
            if let ts = textView.textStorage {
                highlighter?.highlight(ts)
            }
        } else {
            highlighter = nil
            let supportedExts = ["json", "md", "markdown", "yml", "yaml", "py", "python",
                                 "js", "jsx", "ts", "tsx", "c", "h", "cpp", "cc", "cxx", "hpp",
                                 "m", "mm", "css", "html", "xml", "sh", "bash", "zsh",
                                 "rb", "go", "rs", "toml", "java", "kt", "kts"]
            if supportedExts.contains(ext) {
                simpleHighlighter = SimpleHighlighter(theme: theme, fontSize: fontSize, language: ext)
                if let ts = textView.textStorage {
                    simpleHighlighter?.highlight(ts)
                }
            } else {
                simpleHighlighter = nil
            }
        }

        // Apply any existing diagnostics
        applyDiagnosticUnderlines()

        gutterView.textView = textView
        gutterView.onFoldToggle = { [weak self] line in
            self?.toggleFold(at: line)
        }
        updateFoldableLines()
        gutterView.needsDisplay = true

        // Restore saved position or start at top
        if let savedRange = doc.savedSelectionRange,
           savedRange.location + savedRange.length <= (textView.string as NSString).length {
            textView.setSelectedRange(savedRange)
            if let savedScroll = doc.savedScrollPosition {
                scrollView.contentView.scroll(to: savedScroll)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scrollRangeToVisible(savedRange)
            }
        } else {
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        // Fire initial cursor position and line highlight
        notifyCursorPosition()
        updateCurrentLineHighlight()
    }

    /// Sync the editor text back to the document before saving
    func syncDocumentContent() {
        guard let doc = document else { return }
        let editorText = textView.string
        doc.textStorage.beginEditing()
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.textStorage.length), with: editorText)
        doc.textStorage.endEditing()
    }

    // MARK: - Diagnostics

    func updateDiagnostics(_ newDiagnostics: [LSPDiagnostic]) {
        self.diagnostics = newDiagnostics
        applyDiagnosticUnderlines()
        gutterView.diagnosticLines = diagnosticLineNumbers()
        gutterView.diagnosticMessages = diagnosticMessagesByLine()
        gutterView.needsDisplay = true

        // Update minimap diagnostic markers
        minimapView?.diagnosticMarkers = newDiagnostics.map { (line: $0.range.start.line, severity: $0.severity ?? 3) }
        minimapView?.needsDisplay = true
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

    /// Regex for TODO/FIXME/MARK/HACK/WARNING annotations in comments
    private static let annotationRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\b(TODO|FIXME|HACK|WARNING|XXX)(\s*:|\b)"#,
            options: []
        )
    }()

    /// Highlight TODO/FIXME/MARK annotations with distinct colors
    private func highlightAnnotations(in ts: NSTextStorage) {
        guard let regex = Self.annotationRegex else { return }
        let text = ts.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        let matches = regex.matches(in: text as String, range: fullRange)
        for match in matches {
            let range = match.range
            guard range.length > 0, NSMaxRange(range) <= ts.length else { continue }

            let keyword = match.range(at: 1)
            let word = text.substring(with: keyword)

            let styleName: String
            switch word {
            case "FIXME", "HACK", "WARNING", "XXX":
                styleName = "fixme"
            default:
                styleName = "todo"
            }

            if let attrs = theme.attributes(for: styleName, fontSize: fontSize) {
                ts.addAttributes(attrs, range: range)
            }
        }
    }

    private func diagnosticLineNumbers() -> Set<Int> {
        var lines = Set<Int>()
        for d in diagnostics {
            lines.insert(d.range.start.line)
        }
        return lines
    }

    private func diagnosticMessagesByLine() -> [Int: String] {
        var messages: [Int: String] = [:]
        for d in diagnostics {
            let line = d.range.start.line
            if let existing = messages[line] {
                messages[line] = existing + "\n" + d.message
            } else {
                messages[line] = d.message
            }
        }
        return messages
    }

    private func lspRangeToNSRange(_ lspRange: LSPRange, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }

        let startOffset = lineColumnToCharacterIndex(line: lspRange.start.line, column: lspRange.start.character)
        let endOffset = lineColumnToCharacterIndex(line: lspRange.end.line, column: lspRange.end.character)

        guard startOffset <= endOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    // MARK: - Text Change Handling (NSTextDelegate)

    private var completionTriggerWorkItem: DispatchWorkItem?

    func textDidChange(_ notification: Notification) {
        document?.isModified = true
        invalidateLineCache()
        gutterView.needsDisplay = true
        minimapView?.invalidateCodeCache()
        updateLineCount()
        onTextDidChange?()

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

        // Dismiss or auto-trigger completion
        handleCompletionOnTextChange()

        // Check for signature help triggers
        checkSignatureHelp()
    }

    /// Update the gutter's cached first visible line number using the line offset cache.
    private func updateGutterFirstVisibleLine() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        let (line, _) = characterIndexToLineColumn(visibleCharRange.location)
        gutterView.firstVisibleLine = line
    }

    private var scrollRehighlightWorkItem: DispatchWorkItem?

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        updateGutterFirstVisibleLine()
        gutterView.needsDisplay = true
        minimapView?.needsDisplay = true

        // For large files, rehighlight visible range on scroll (debounced)
        if let ts = textView.textStorage, ts.length > Self.largeFileThreshold {
            scrollRehighlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.rehighlight()
            }
            scrollRehighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateGutterFirstVisibleLine()
        gutterView.needsDisplay = true
        notifyCursorPosition()
        updateCurrentLineHighlight()
        updateBracketMatch()

        // Debounce occurrence highlighting to avoid lag during rapid selection changes
        occurrenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateOccurrenceHighlights()
        }
        occurrenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var cachedTotalLines: Int = 1

    /// Update cached total line count (call on text change)
    private func updateLineCount() {
        cachedTotalLines = lineStartOffsets.count
        updateGutterWidth()
    }

    /// Recompute gutter width based on total line count
    private func updateGutterWidth() {
        let digits = max(3, String(cachedTotalLines).count)
        // Approximate: 8pt per digit + 14pt padding for diagnostics/fold markers
        let newWidth = CGFloat(digits) * 8.0 + 14.0
        let rounded = ceil(newWidth / 2.0) * 2.0 // round to even
        if rounded != gutterWidth {
            gutterWidth = rounded
            onGutterWidthChange?(rounded)
        }
    }

    private func notifyCursorPosition() {
        let sel = textView.selectedRange()
        let (zeroLine, zeroCol) = characterIndexToLineColumn(sel.location)
        onCursorChange?(zeroLine + 1, zeroCol + 1, cachedTotalLines, sel.length)
    }

    /// Threshold for switching to visible-range-only highlighting (characters)
    private static let largeFileThreshold = 100_000

    private func rehighlight() {
        guard let ts = textView.textStorage else { return }
        let selectedRange = textView.selectedRange()
        let isLarge = ts.length > Self.largeFileThreshold

        if let highlighter = highlighter {
            let text = ts.string
            highlighter.parse(text)
            if isLarge, let visibleRange = visibleCharacterRange() {
                // For large files, only highlight the visible portion + margin
                let margin = 2000
                let expandedStart = max(0, visibleRange.location - margin)
                let expandedEnd = min(ts.length, NSMaxRange(visibleRange) + margin)
                let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
                highlighter.highlight(ts, in: expandedRange)
            } else {
                highlighter.highlight(ts)
            }
        } else if let simple = simpleHighlighter {
            if isLarge, let visibleRange = visibleCharacterRange() {
                simple.highlight(ts, in: visibleRange)
            } else {
                simple.highlight(ts)
            }
        }

        highlightAnnotations(in: ts)
        colorizeBracketPairs(in: ts)
        applyDiagnosticUnderlines()
        updateCurrentLineHighlight()
        textView.setSelectedRange(selectedRange)
    }

    private func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    // MARK: - Bracket Pair Colorization

    /// Colors for bracket nesting levels — cycles through these
    private static let bracketColors: [NSColor] = [
        NSColor(red: 0.87, green: 0.75, blue: 0.26, alpha: 1.0),  // gold
        NSColor(red: 0.68, green: 0.39, blue: 0.87, alpha: 1.0),  // purple
        NSColor(red: 0.27, green: 0.70, blue: 0.83, alpha: 1.0),  // cyan
        NSColor(red: 0.87, green: 0.46, blue: 0.27, alpha: 1.0),  // orange
        NSColor(red: 0.55, green: 0.78, blue: 0.33, alpha: 1.0),  // green
        NSColor(red: 0.83, green: 0.37, blue: 0.55, alpha: 1.0),  // pink
    ]

    private func colorizeBracketPairs(in ts: NSTextStorage) {
        guard Preferences.shared.bracketPairColorization else { return }

        let text = ts.string as NSString
        let length = text.length
        guard length > 0, length < 200_000 else { return } // Skip for very large files

        // Copy to a UTF-16 buffer for fast access (avoids per-character ObjC calls)
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: length)
        defer { buffer.deallocate() }
        text.getCharacters(buffer, range: NSRange(location: 0, length: length))

        var depth = 0
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var i = 0

        ts.beginEditing()

        while i < length {
            let ch = buffer[i]

            // Skip line comments
            if inLineComment {
                if ch == 0x0A { // \n
                    inLineComment = false
                }
                i += 1
                continue
            }

            // Skip block comments
            if inBlockComment {
                if ch == 0x2A && i + 1 < length && buffer[i + 1] == 0x2F { // */
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            // Check for comment start
            if ch == 0x2F && i + 1 < length { // /
                let next = buffer[i + 1]
                if next == 0x2F { // //
                    inLineComment = true
                    i += 2
                    continue
                } else if next == 0x2A { // /*
                    inBlockComment = true
                    i += 2
                    continue
                }
            }

            // Toggle string mode on unescaped quote
            if ch == 0x22 { // "
                let escaped = i > 0 && buffer[i - 1] == 0x5C // backslash
                if !escaped {
                    inString = !inString
                }
                i += 1
                continue
            }

            if inString {
                i += 1
                continue
            }

            // Bracket characters
            let isOpen = ch == 0x28 || ch == 0x5B || ch == 0x7B    // ( [ {
            let isClose = ch == 0x29 || ch == 0x5D || ch == 0x7D   // ) ] }

            if isOpen {
                let colorIndex = depth % Self.bracketColors.count
                ts.addAttribute(.foregroundColor, value: Self.bracketColors[colorIndex], range: NSRange(location: i, length: 1))
                depth += 1
            } else if isClose {
                depth = max(0, depth - 1)
                let colorIndex = depth % Self.bracketColors.count
                ts.addAttribute(.foregroundColor, value: Self.bracketColors[colorIndex], range: NSRange(location: i, length: 1))
            }

            i += 1
        }

        ts.endEditing()
    }

    private func notifyLSPChange() {
        guard let doc = document, let ts = textView.textStorage else { return }
        lspClient?.didChange(url: doc.url, text: ts.string)
    }

    // MARK: - Rename Symbol (⌃⌘E)

    @objc func renameSymbol(_ sender: Any?) {
        guard let doc = document, let lsp = lspClient else { return }

        // Get the word under cursor
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        let wordRange = wordRangeAtIndex(cursor, in: text)
        guard wordRange.length > 0 else { return }

        let currentWord = text.substring(with: wordRange)
        let (line, character) = characterIndexToLineColumn(cursor)

        let alert = NSAlert()
        alert.messageText = "Rename Symbol"
        alert.informativeText = "Enter the new name for '\(currentWord)':"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = currentWord
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty && newName != currentWord else { return }

        Task { @MainActor in
            do {
                guard let workspaceEdit = try await lsp.rename(url: doc.url, line: line, character: character, newName: newName) else { return }

                // Apply edits to the current document
                if let edits = workspaceEdit.changes[doc.url] {
                    applyTextEdits(edits)
                }

                // Notify about edits in other files
                for (url, edits) in workspaceEdit.changes where url != doc.url {
                    onApplyEdits?(url, edits)
                }
            } catch {
                // Rename not supported or failed — silently ignore
            }
        }
    }

    private func applyTextEdits(_ edits: [LSPTextEdit]) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString

        // Sort edits in reverse order to avoid offset issues
        let sortedEdits = edits.sorted { a, b in
            if a.range.start.line != b.range.start.line {
                return a.range.start.line > b.range.start.line
            }
            return a.range.start.character > b.range.start.character
        }

        for edit in sortedEdits {
            guard let nsRange = lspRangeToNSRange(edit.range, in: text) else { continue }
            if textView.shouldChangeText(in: nsRange, replacementString: edit.newText) {
                ts.replaceCharacters(in: nsRange, with: edit.newText)
                textView.didChangeText()
            }
        }
    }

    // MARK: - Find All References

    @objc func findReferences(_ sender: Any?) {
        guard let doc = document, let lsp = lspClient else { return }
        let (line, character) = characterIndexToLineColumn(textView.selectedRange().location)

        Task { @MainActor in
            do {
                let locations = try await lsp.references(url: doc.url, line: line, character: character)
                guard !locations.isEmpty else { return }
                self.onShowReferences?(locations)
            } catch {
                // Silently fail
            }
        }
    }

    // MARK: - Font Size Zoom

    func increaseFontSize() {
        fontSize = min(fontSize + 1, 32)
        Preferences.shared.fontSize = fontSize
        applyFontSize()
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - 1, 8)
        Preferences.shared.fontSize = fontSize
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = 13
        Preferences.shared.fontSize = fontSize
        applyFontSize()
    }

    private func applyFontSize() {
        textView.font = editorFont
        if let doc = document {
            // Re-display to apply new font size to highlighting
            displayDocument(doc)
        }
    }

    // MARK: - Undo Manager per Document

    func undoManager(for view: NSTextView) -> UndoManager? {
        return document?.undoManager
    }

    // MARK: - NSTextViewDelegate (Tab-to-spaces, Auto-indent)

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let sel = textView.selectedRange()
            if sel.length > 0 {
                // Block indent selection
                indentSelection(textView, indent: true)
            } else {
                let spaces = String(repeating: " ", count: tabWidth)
                textView.insertText(spaces, replacementRange: sel)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // Shift-Tab: outdent selection or current line
            indentSelection(textView, indent: false)
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            autoIndentNewline(textView)
            return true
        }

        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            // Delete matching closing bracket/quote if we just auto-inserted it
            return handleDeleteMatchingBracket(textView)
        }

        return false
    }

    private func indentSelection(_ textView: NSTextView, indent: Bool) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)
        let linesText = text.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")
        let spaces = String(repeating: " ", count: tabWidth)

        var newLines: [String] = []
        for line in lines {
            if indent {
                newLines.append(spaces + line)
            } else {
                // Remove up to tabWidth spaces from the beginning
                var removed = 0
                var startIndex = line.startIndex
                while removed < tabWidth && startIndex < line.endIndex && line[startIndex] == " " {
                    startIndex = line.index(after: startIndex)
                    removed += 1
                }
                newLines.append(String(line[startIndex...]))
            }
        }

        let newText = newLines.joined(separator: "\n")
        if textView.shouldChangeText(in: lineRange, replacementString: newText) {
            ts.replaceCharacters(in: lineRange, with: newText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (newText as NSString).length))
        }
    }

    /// Intercept typed text for auto-closing brackets/quotes
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacement = replacementString, replacement.count == 1 else { return true }

        let closing: String?
        switch replacement {
        case "(": closing = ")"
        case "[": closing = "]"
        case "{": closing = "}"
        case "\"": closing = "\""
        default: closing = nil
        }

        if let close = closing {
            // Surround selection with bracket/quote pair
            if affectedCharRange.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: affectedCharRange)
                let wrapped = replacement + selectedText + close
                textView.insertText(wrapped, replacementRange: affectedCharRange)
                // Select the wrapped content (without the brackets)
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: affectedCharRange.length))
                return false
            }

            // For quotes, only auto-close if not already inside quotes (simple heuristic)
            if replacement == "\"" {
                let text = textView.string as NSString
                if affectedCharRange.location < text.length &&
                   text.character(at: affectedCharRange.location) == UInt16(Character("\"").asciiValue!) {
                    // Skip over the closing quote instead
                    textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                    return false
                }
            }

            // Insert pair
            let pair = replacement + close
            textView.insertText(pair, replacementRange: affectedCharRange)
            // Place cursor between the brackets
            textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
            return false
        }

        // Closing bracket handling: skip-over or auto-deindent
        if replacement == ")" || replacement == "]" || replacement == "}" {
            let text = textView.string as NSString

            // Skip over matching bracket if it's the next character
            if affectedCharRange.location < text.length {
                let nextChar = text.character(at: affectedCharRange.location)
                if let scalar = UnicodeScalar(nextChar),
                   String(Character(scalar)) == replacement {
                    textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                    return false
                }
            }

            // Auto-deindent: if line prefix is only whitespace, reduce indent by one level
            let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let lineStart = lineRange.location
            let prefixLength = affectedCharRange.location - lineStart
            if prefixLength > 0 {
                let prefix = text.substring(with: NSRange(location: lineStart, length: prefixLength))
                if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    let newIndent = max(0, prefix.count - tabWidth)
                    let newPrefix = String(repeating: " ", count: newIndent)
                    let replaceRange = NSRange(location: lineStart, length: prefixLength)
                    textView.insertText(newPrefix + replacement, replacementRange: replaceRange)
                    return false
                }
            }
        }

        return true
    }

    private func handleDeleteMatchingBracket(_ textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        guard cursor > 0 && cursor < text.length else { return false }

        let before = text.character(at: cursor - 1)
        let after = text.character(at: cursor)

        let pairs: [(UInt16, UInt16)] = [
            (UInt16(Character("(").asciiValue!), UInt16(Character(")").asciiValue!)),
            (UInt16(Character("[").asciiValue!), UInt16(Character("]").asciiValue!)),
            (UInt16(Character("{").asciiValue!), UInt16(Character("}").asciiValue!)),
            (UInt16(Character("\"").asciiValue!), UInt16(Character("\"").asciiValue!)),
        ]

        for (open, close) in pairs {
            if before == open && after == close {
                // Delete both characters
                textView.insertText("", replacementRange: NSRange(location: cursor - 1, length: 2))
                return true
            }
        }

        return false
    }

    private func autoIndentNewline(_ textView: NSTextView) {
        let text = textView.string as NSString
        let cursorLocation = textView.selectedRange().location

        let lineRange = text.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let lineStart = lineRange.location
        let lineText = text.substring(with: NSRange(location: lineStart, length: cursorLocation - lineStart))

        // Extract leading whitespace
        var indent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }

        // Add extra indent after { or (
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        let needsExtraIndent = trimmed.hasSuffix("{") || trimmed.hasSuffix("(")
        if needsExtraIndent {
            indent += String(repeating: " ", count: tabWidth)
        }

        // Check if cursor is between matching brackets: {|} or (|)
        let afterCursor: String
        if cursorLocation < text.length,
           let scalar = UnicodeScalar(text.character(at: cursorLocation)) {
            afterCursor = String(Character(scalar))
        } else {
            afterCursor = ""
        }
        if needsExtraIndent && (afterCursor == "}" || afterCursor == ")") {
            // Insert new line with extra indent, plus closing bracket on its own line
            let closingIndent = String(indent.dropLast(tabWidth))
            textView.insertText("\n" + indent + "\n" + closingIndent, replacementRange: textView.selectedRange())
            // Move cursor to the middle line
            let newCursorPos = cursorLocation + 1 + indent.count
            textView.setSelectedRange(NSRange(location: newCursorPos, length: 0))
        } else {
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
        }
    }

    // MARK: - Toggle Comment (⌘/)

    /// Returns the line comment prefix for the current file type
    private var commentPrefix: String {
        guard let ext = document?.fileExtension.lowercased() else { return "//" }
        switch ext {
        case "py", "python", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml", "r":
            return "#"
        case "lua":
            return "--"
        case "sql":
            return "--"
        case "hs":
            return "--"
        default:
            return "//"
        }
    }

    @objc func toggleComment(_ sender: Any?) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let prefix = commentPrefix

        let lineRange = text.lineRange(for: sel)
        let linesText = text.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = nonEmptyLines.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }

        var newLines: [String] = []
        for line in lines {
            if allCommented {
                if let range = line.range(of: "\(prefix) ") {
                    var newLine = line
                    newLine.removeSubrange(range)
                    newLines.append(newLine)
                } else if let range = line.range(of: prefix) {
                    var newLine = line
                    newLine.removeSubrange(range)
                    newLines.append(newLine)
                } else {
                    newLines.append(line)
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    newLines.append(line)
                } else {
                    let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                    let rest = line.dropFirst(indent.count)
                    newLines.append(String(indent) + "\(prefix) " + rest)
                }
            }
        }

        let newText = newLines.joined(separator: "\n")
        if textView.shouldChangeText(in: lineRange, replacementString: newText) {
            ts.replaceCharacters(in: lineRange, with: newText)
            textView.didChangeText()
            let newRange = NSRange(location: lineRange.location, length: (newText as NSString).length)
            textView.setSelectedRange(newRange)
        }
    }

    // MARK: - Occurrence Highlighting

    private let occurrenceHighlightColor = NSColor(red: 0.30, green: 0.35, blue: 0.45, alpha: 0.5)

    private func updateOccurrenceHighlights() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString

        // Clear previous highlights
        ts.beginEditing()
        for range in occurrenceHighlightRanges {
            if range.location + range.length <= ts.length {
                ts.removeAttribute(.backgroundColor, range: range)
            }
        }
        occurrenceHighlightRanges.removeAll()

        // Get selected word
        let sel = textView.selectedRange()
        guard sel.length == 0, text.length > 0 else {
            ts.endEditing()
            updateCurrentLineHighlight()
            return
        }

        let cursor = min(sel.location, text.length)
        let wordRange = wordRangeAtIndex(cursor, in: text)
        guard wordRange.length >= 2 else {
            ts.endEditing()
            updateCurrentLineHighlight()
            return
        }

        let word = text.substring(with: wordRange)

        // Find all occurrences of the word
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.location < text.length {
            let foundRange = text.range(of: word, options: .literal, range: searchRange)
            guard foundRange.location != NSNotFound else { break }

            // Only highlight whole word matches
            let before = foundRange.location > 0 ? text.character(at: foundRange.location - 1) : UInt16(0x20)
            let after = NSMaxRange(foundRange) < text.length ? text.character(at: NSMaxRange(foundRange)) : UInt16(0x20)

            let isWordBoundaryBefore = !isIdentChar(before)
            let isWordBoundaryAfter = !isIdentChar(after)

            if isWordBoundaryBefore && isWordBoundaryAfter && foundRange != wordRange {
                ts.addAttribute(.backgroundColor, value: occurrenceHighlightColor, range: foundRange)
                occurrenceHighlightRanges.append(foundRange)
            }

            searchRange.location = NSMaxRange(foundRange)
            searchRange.length = text.length - searchRange.location
        }

        ts.endEditing()
        updateCurrentLineHighlight()
    }

    private func wordRangeAtIndex(_ index: Int, in text: NSString) -> NSRange {
        guard index < text.length else { return NSRange(location: index, length: 0) }

        var start = index
        var end = index

        // Expand backwards
        while start > 0 && isIdentChar(text.character(at: start - 1)) {
            start -= 1
        }

        // Expand forwards
        while end < text.length && isIdentChar(text.character(at: end)) {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private func isIdentChar(_ ch: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    // MARK: - Bracket Matching

    private let bracketHighlightColor = NSColor(red: 0.40, green: 0.50, blue: 0.60, alpha: 0.5)
    private static let bracketPairs: [(open: UInt16, close: UInt16)] = [
        (UInt16(Character("(").asciiValue!), UInt16(Character(")").asciiValue!)),
        (UInt16(Character("[").asciiValue!), UInt16(Character("]").asciiValue!)),
        (UInt16(Character("{").asciiValue!), UInt16(Character("}").asciiValue!)),
    ]

    private func updateBracketMatch() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString

        ts.beginEditing()

        // Clear previous bracket highlight
        if let prev = bracketMatchRange, prev.location + prev.length <= ts.length {
            ts.removeAttribute(.backgroundColor, range: prev)
        }
        bracketMatchRange = nil

        let cursor = textView.selectedRange().location
        guard cursor > 0, text.length > 0 else {
            ts.endEditing()
            return
        }

        let charBefore = text.character(at: cursor - 1)

        // Check if char before cursor is a bracket
        for pair in Self.bracketPairs {
            if charBefore == pair.close {
                // Search backwards for matching open bracket
                if let matchIndex = findMatchingBracket(in: text, at: cursor - 1, open: pair.open, close: pair.close, forward: false) {
                    let range = NSRange(location: matchIndex, length: 1)
                    ts.addAttribute(.backgroundColor, value: bracketHighlightColor, range: range)
                    bracketMatchRange = range
                }
                break
            } else if charBefore == pair.open {
                // Search forwards for matching close bracket
                if let matchIndex = findMatchingBracket(in: text, at: cursor - 1, open: pair.open, close: pair.close, forward: true) {
                    let range = NSRange(location: matchIndex, length: 1)
                    ts.addAttribute(.backgroundColor, value: bracketHighlightColor, range: range)
                    bracketMatchRange = range
                }
                break
            }
        }

        ts.endEditing()
    }

    private func findMatchingBracket(in text: NSString, at index: Int, open: UInt16, close: UInt16, forward: Bool) -> Int? {
        var depth = 0
        if forward {
            for i in (index + 1)..<text.length {
                let ch = text.character(at: i)
                if ch == open { depth += 1 }
                if ch == close {
                    if depth == 0 { return i }
                    depth -= 1
                }
            }
        } else {
            for i in stride(from: index - 1, through: 0, by: -1) {
                let ch = text.character(at: i)
                if ch == close { depth += 1 }
                if ch == open {
                    if depth == 0 { return i }
                    depth -= 1
                }
            }
        }
        return nil
    }

    // MARK: - Re-indent Selection (⌃I)

    @objc func reindentSelection(_ sender: Any?) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)
        let linesText = text.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        var result: [String] = []
        var indentLevel = 0

        // Determine starting indent level from context above
        if lineRange.location > 0 {
            let contextRange = NSRange(location: 0, length: lineRange.location)
            let contextText = text.substring(with: contextRange)
            for ch in contextText {
                if ch == "{" || ch == "(" { indentLevel += 1 }
                if ch == "}" || ch == ")" { indentLevel = max(0, indentLevel - 1) }
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append("")
                continue
            }

            // Decrease indent for closing braces at the start of the line
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]") {
                indentLevel = max(0, indentLevel - 1)
            }

            let indent = String(repeating: " ", count: indentLevel * tabWidth)
            result.append(indent + trimmed)

            // Increase indent after opening braces
            for ch in trimmed {
                if ch == "{" || ch == "(" { indentLevel += 1 }
                if ch == "}" || ch == ")" { indentLevel = max(0, indentLevel - 1) }
            }
        }

        let newText = result.joined(separator: "\n")
        if textView.shouldChangeText(in: lineRange, replacementString: newText) {
            ts.replaceCharacters(in: lineRange, with: newText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (newText as NSString).length))
        }
    }

    // MARK: - Current Line Highlight

    private func updateCurrentLineHighlight() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        guard text.length > 0 else { return }

        ts.beginEditing()

        // Clear previous highlight
        if let prev = currentLineRange, prev.location + prev.length <= ts.length {
            ts.removeAttribute(.backgroundColor, range: prev)
        }

        // Apply new highlight
        let cursorLoc = min(textView.selectedRange().location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: cursorLoc, length: 0))
        ts.addAttribute(.backgroundColor, value: theme.currentLine, range: lineRange)
        currentLineRange = lineRange

        ts.endEditing()
    }

    // MARK: - Jump to Definition (⌘-click)

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }

            // Check if click is in our text view
            let locationInTextView = self.textView.convert(event.locationInWindow, from: nil)
            guard self.textView.bounds.contains(locationInTextView) else {
                return event
            }

            // ⌘-click → jump to definition
            if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) {
                self.handleJumpToDefinition(at: locationInTextView)
                return nil
            }

            // ⌥-click → Quick Help hover
            if event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command) {
                self.handleHover(at: locationInTextView)
                return nil
            }

            return event
        }
    }

    private func handleJumpToDefinition(at point: NSPoint) {
        guard let doc = document, let lsp = lspClient else { return }

        // Convert point to character index
        let charIndex = textView.characterIndexForInsertion(at: point)
        guard charIndex != NSNotFound else { return }

        // Convert character index to line/character (0-based for LSP)
        let (line, character) = characterIndexToLineColumn(charIndex)

        Task { @MainActor in
            do {
                let locations = try await lsp.definition(url: doc.url, line: line, character: character)
                guard let loc = locations.first,
                      let url = URL(string: loc.uri) else { return }
                self.onJumpToDefinition?(url, loc.range.start.line, loc.range.start.character)
            } catch {
                // Silently fail — no definition found is normal
            }
        }
    }

    // MARK: - Quick Help Hover (⌥-click)

    private func handleHover(at point: NSPoint) {
        guard let doc = document, let lsp = lspClient else { return }

        let charIndex = textView.characterIndexForInsertion(at: point)
        guard charIndex != NSNotFound else { return }

        let (line, character) = characterIndexToLineColumn(charIndex)

        Task { @MainActor in
            do {
                guard let hoverText = try await lsp.hover(url: doc.url, line: line, character: character),
                      !hoverText.isEmpty else { return }
                self.showHoverPopover(text: hoverText, at: charIndex)
            } catch {
                // No hover info available — normal
            }
        }
    }

    private func showHoverPopover(text: String, at charIndex: Int) {
        hoverPopover?.close()

        guard let layoutManager = textView.layoutManager else { return }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(charIndex, textView.string.count - 1))
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphIndex)

        var rect = NSRect(
            x: lineRect.origin.x + location.x + textView.textContainerInset.width,
            y: lineRect.origin.y + textView.textContainerInset.height,
            width: 1,
            height: lineRect.height
        )

        // Adjust for scroll position
        let visibleRect = scrollView.contentView.bounds
        rect.origin.y -= visibleRect.origin.y
        rect.origin.x -= visibleRect.origin.x

        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.textColor = NSColor(white: 0.85, alpha: 1.0)
        textField.maximumNumberOfLines = 20
        textField.preferredMaxLayoutWidth = 500

        let vc = NSViewController()
        let container = NSView()
        textField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        vc.view = container

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true

        // Convert rect to scrollView's clip view coordinate space
        let showRect = NSRect(
            x: rect.origin.x + scrollView.contentView.frame.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )

        popover.show(relativeTo: showRect, of: scrollView.contentView, preferredEdge: .maxY)
        hoverPopover = popover
    }

    // MARK: - Code Completion

    func triggerCompletion() {
        guard let doc = document, let lsp = lspClient else { return }
        let (line, character) = characterIndexToLineColumn(textView.selectedRange().location)

        Task { @MainActor in
            do {
                let items = try await lsp.completion(url: doc.url, line: line, character: character)
                guard !items.isEmpty else {
                    completionWindow?.dismiss()
                    return
                }
                self.showCompletionWindow(with: items)
            } catch {
                completionWindow?.dismiss()
            }
        }
    }

    private func showCompletionWindow(with items: [LSPCompletionItem]) {
        guard let window = textView.window else { return }

        if completionWindow == nil {
            completionWindow = CompletionWindow()
        }

        // Get cursor position on screen
        let cursorRect = cursorScreenRect()

        completionWindow?.show(items: items, at: cursorRect, in: window) { [weak self] item in
            self?.insertCompletion(item)
        }
    }

    private func cursorScreenRect() -> NSPoint {
        guard let layoutManager = textView.layoutManager,
              textView.textContainer != nil else {
            return .zero
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: textView.selectedRange().location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphIndex, layoutManager.numberOfGlyphs - 1), effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: min(glyphIndex, layoutManager.numberOfGlyphs - 1))

        var point = NSPoint(
            x: lineRect.origin.x + location.x + textView.textContainerInset.width,
            y: lineRect.origin.y + lineRect.height + textView.textContainerInset.height
        )

        // Convert from text view coordinates to window coordinates
        point = textView.convert(point, to: nil)
        return point
    }

    private func insertCompletion(_ item: LSPCompletionItem) {
        let insertText = item.insertText ?? item.label

        // Find the prefix the user already typed to avoid duplication
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        var prefixStart = cursor
        while prefixStart > 0 {
            let ch = text.character(at: prefixStart - 1)
            guard let scalar = Unicode.Scalar(ch) else { break }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." {
                prefixStart -= 1
            } else {
                break
            }
        }

        // Check how much of the insertion text overlaps with what's already typed
        let existingPrefix = text.substring(with: NSRange(location: prefixStart, length: cursor - prefixStart))

        // If the completion starts with the existing prefix, only insert the remainder
        if insertText.hasPrefix(existingPrefix) {
            let remainder = String(insertText.dropFirst(existingPrefix.count))
            textView.insertText(remainder, replacementRange: textView.selectedRange())
        } else {
            // Replace the prefix entirely
            let replaceRange = NSRange(location: prefixStart, length: cursor - prefixStart)
            textView.insertText(insertText, replacementRange: replaceRange)
        }
    }

    /// Position where the current completion prefix starts
    private var completionPrefixStart: Int = 0

    private func handleCompletionOnTextChange() {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        guard cursor > 0 else {
            completionWindow?.dismiss()
            return
        }

        let ch = text.character(at: cursor - 1)
        guard let scalar = Unicode.Scalar(ch) else { return }
        let isIdent = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"

        if String(Character(scalar)) == "." {
            // Auto-trigger completion after `.` with a short delay
            completionPrefixStart = cursor
            completionTriggerWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.triggerCompletion()
            }
            completionTriggerWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else if isIdent && completionWindow?.isShowing == true {
            // Completion is showing — re-filter with updated prefix
            guard cursor > completionPrefixStart else {
                completionWindow?.dismiss()
                return
            }
            let prefix = text.substring(with: NSRange(location: completionPrefixStart, length: cursor - completionPrefixStart))
            completionWindow?.filterItems(prefix: prefix)
        } else if isIdent {
            // Not showing — check if we should auto-trigger
            var wordStart = cursor - 1
            while wordStart > 0 && isIdentChar(text.character(at: wordStart - 1)) {
                wordStart -= 1
            }
            let wordLen = cursor - wordStart
            if wordLen >= 3 {
                completionPrefixStart = wordStart
                completionTriggerWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.triggerCompletion()
                }
                completionTriggerWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        } else {
            // Non-identifier character — dismiss
            completionWindow?.dismiss()
        }
    }

    // Handle ⌃Space, completion keyboard navigation, and move line
    func handleKeyForCompletion(_ event: NSEvent) -> Bool {
        // ⌃Space → trigger completion
        if event.modifierFlags.contains(.control) && event.keyCode == 49 { // space
            triggerCompletion()
            return true
        }

        // ⌘⌥[ → move line up, ⌘⌥] → move line down
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if mods == [.command, .option] {
            if event.keyCode == 33 { // [ key
                moveLineUp(nil)
                return true
            } else if event.keyCode == 30 { // ] key
                moveLineDown(nil)
                return true
            }
        }

        // ⌘⇧D → duplicate line
        if mods == [.command, .shift] && event.keyCode == 2 { // D key
            duplicateLine(nil)
            return true
        }

        // ⌃⇧K → delete line
        if mods == [.control, .shift] && event.keyCode == 40 { // K key
            deleteLine(nil)
            return true
        }

        // ⌘⇧↩ → insert line above
        if mods == [.command, .shift] && event.keyCode == 36 { // Return
            insertLineAbove(nil)
            return true
        }

        // ⌘↩ → insert line below
        if mods == [.command] && event.keyCode == 36 { // Return
            insertLineBelow(nil)
            return true
        }

        // ⌃J → join lines
        if mods == [.control] && event.keyCode == 38 { // J key
            joinLines(nil)
            return true
        }

        // ⌘⇧L → select all occurrences of word
        if mods == [.command, .shift] && event.keyCode == 37 { // L key
            selectAllOccurrences()
            return true
        }

        // ⌃⇧⌘→ → select enclosing brackets
        if mods == [.control, .shift, .command] && event.keyCode == 124 { // right arrow
            selectEnclosingBrackets(nil)
            return true
        }

        // If completion window is showing, handle navigation keys
        guard let cw = completionWindow, cw.isShowing else { return false }

        switch event.keyCode {
        case 126: // up arrow
            cw.moveSelectionUp()
            return true
        case 125: // down arrow
            cw.moveSelectionDown()
            return true
        case 36, 48: // return, tab
            cw.confirmSelection()
            return true
        case 53: // escape
            cw.dismiss()
            return true
        default:
            return false
        }
    }

    // MARK: - Move Line Up/Down

    @objc func moveLineUp(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)

        guard lineRange.location > 0 else { return } // already at top

        let prevLineRange = text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
        let prevLine = text.substring(with: prevLineRange)
        let currentLines = text.substring(with: lineRange)

        let combined = currentLines + prevLine
        let fullRange = NSRange(location: prevLineRange.location, length: prevLineRange.length + lineRange.length)

        if textView.shouldChangeText(in: fullRange, replacementString: combined) {
            ts.replaceCharacters(in: fullRange, with: combined)
            textView.didChangeText()

            // Adjust selection
            let offset = sel.location - lineRange.location + prevLineRange.location
            textView.setSelectedRange(NSRange(location: offset, length: sel.length))
        }
    }

    @objc func moveLineDown(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)
        let lineEnd = NSMaxRange(lineRange)

        guard lineEnd < text.length else { return } // already at bottom

        let nextLineRange = text.lineRange(for: NSRange(location: lineEnd, length: 0))
        let nextLine = text.substring(with: nextLineRange)
        let currentLines = text.substring(with: lineRange)

        let combined = nextLine + currentLines
        let fullRange = NSRange(location: lineRange.location, length: lineRange.length + nextLineRange.length)

        if textView.shouldChangeText(in: fullRange, replacementString: combined) {
            ts.replaceCharacters(in: fullRange, with: combined)
            textView.didChangeText()

            // Adjust selection
            let offset = sel.location - lineRange.location + lineRange.location + nextLineRange.length
            textView.setSelectedRange(NSRange(location: offset, length: sel.length))
        }
    }

    // MARK: - Duplicate Line

    @objc func duplicateLine(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)
        let lineText = text.substring(with: lineRange)

        // Insert a copy after the current line
        let insertPoint = NSMaxRange(lineRange)
        let insertText = lineText.hasSuffix("\n") ? lineText : lineText + "\n"

        if textView.shouldChangeText(in: NSRange(location: insertPoint, length: 0), replacementString: insertText) {
            ts.insert(NSAttributedString(string: insertText, attributes: [
                .font: editorFont,
                .foregroundColor: theme.foreground,
            ]), at: insertPoint)
            textView.didChangeText()

            // Move cursor to the duplicated line
            let newCursorPos = insertPoint + (sel.location - lineRange.location)
            textView.setSelectedRange(NSRange(location: newCursorPos, length: sel.length))
        }
    }

    // MARK: - Join Lines (⌃J)

    @objc func joinLines(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)

        // Find the end of current line (before newline)
        let lineEnd = NSMaxRange(lineRange)
        guard lineEnd <= text.length else { return }

        // The current line includes the trailing newline
        let lineText = text.substring(with: lineRange)
        guard lineText.hasSuffix("\n"), lineEnd < text.length else { return }

        // Get the next line's leading whitespace to remove
        let nextLineRange = text.lineRange(for: NSRange(location: lineEnd, length: 0))
        let nextLineText = text.substring(with: nextLineRange)
        let trimmedNext = nextLineText.trimmingCharacters(in: .whitespaces)

        // Replace: current line (minus newline) + space + next line (trimmed)
        let currentWithoutNewline = String(lineText.dropLast())
        let joined = currentWithoutNewline + " " + trimmedNext
        let replaceRange = NSRange(location: lineRange.location, length: lineRange.length + nextLineRange.length)

        if textView.shouldChangeText(in: replaceRange, replacementString: joined) {
            ts.replaceCharacters(in: replaceRange, with: joined)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location + currentWithoutNewline.count, length: 0))
        }
    }

    // MARK: - Select All Occurrences (⌘⇧L)

    private func selectAllOccurrences() {
        let text = textView.string as NSString
        guard text.length > 0, let ts = textView.textStorage else { return }

        let sel = textView.selectedRange()
        let selectedText: String

        if sel.length > 0 {
            selectedText = text.substring(with: sel)
        } else {
            let wordRange = wordRangeAtIndex(min(sel.location, text.length), in: text)
            guard wordRange.length > 0 else { return }
            selectedText = text.substring(with: wordRange)
        }

        // Find all occurrences
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.location < text.length {
            let found = text.range(of: selectedText, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchRange.location = NSMaxRange(found)
            searchRange.length = text.length - searchRange.location
        }

        guard !ranges.isEmpty else { return }

        // Select the first occurrence
        textView.setSelectedRange(ranges[0])

        // Highlight all occurrences with a bright color
        let highlightColor = NSColor(red: 0.45, green: 0.55, blue: 0.20, alpha: 0.5)
        ts.beginEditing()
        // Clear previous highlights
        for range in occurrenceHighlightRanges {
            if range.location + range.length <= ts.length {
                ts.removeAttribute(.backgroundColor, range: range)
            }
        }
        occurrenceHighlightRanges.removeAll()

        for range in ranges {
            ts.addAttribute(.backgroundColor, value: highlightColor, range: range)
            occurrenceHighlightRanges.append(range)
        }
        ts.endEditing()

        // Populate the find pasteboard so ⌘G works to cycle through matches
        let pb = NSPasteboard(name: .find)
        pb.clearContents()
        pb.setString(selectedText, forType: .string)

        // Open the find bar pre-populated (tag 1 = show find panel)
        let menuItem = NSMenuItem()
        menuItem.tag = 1
        textView.performFindPanelAction(menuItem)
    }

    // MARK: - Jump to Issue

    @objc func jumpToNextIssue(_ sender: Any?) {
        jumpToIssue(forward: true)
    }

    @objc func jumpToPreviousIssue(_ sender: Any?) {
        jumpToIssue(forward: false)
    }

    private func jumpToIssue(forward: Bool) {
        guard !diagnostics.isEmpty else { return }
        let cursorPos = textView.selectedRange().location
        let (currentLine, _) = characterIndexToLineColumn(cursorPos)

        // Sort diagnostics by line
        let sorted = diagnostics.sorted { $0.range.start.line < $1.range.start.line }

        if forward {
            // Find next diagnostic after current line
            let target = sorted.first(where: { $0.range.start.line > currentLine }) ?? sorted.first
            if let target = target {
                scrollToLine(target.range.start.line, column: target.range.start.character)
            }
        } else {
            // Find previous diagnostic before current line
            let target = sorted.last(where: { $0.range.start.line < currentLine }) ?? sorted.last
            if let target = target {
                scrollToLine(target.range.start.line, column: target.range.start.character)
            }
        }
    }

    // MARK: - Select Enclosing Brackets (⌃⇧⌘→)

    @objc func selectEnclosingBrackets(_ sender: Any?) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let cursor = textView.selectedRange().location
        let openBrackets: [unichar] = [0x28, 0x5B, 0x7B] // ( [ {
        let closeBrackets: [unichar] = [0x29, 0x5D, 0x7D] // ) ] }

        // Search backward for unmatched open bracket
        var depth: [unichar: Int] = [:]
        var openPos = -1
        var openChar: unichar = 0

        var i = cursor - 1
        while i >= 0 {
            let ch = text.character(at: i)
            if closeBrackets.contains(ch) {
                depth[ch, default: 0] += 1
            } else if openBrackets.contains(ch) {
                let closeIdx = openBrackets.firstIndex(of: ch)!
                let closeCh = closeBrackets[closeIdx]
                let d = depth[closeCh, default: 0]
                if d > 0 {
                    depth[closeCh] = d - 1
                } else {
                    openPos = i
                    openChar = ch
                    break
                }
            }
            i -= 1
        }

        guard openPos >= 0 else { return }

        // Search forward for matching close bracket
        let openIdx = openBrackets.firstIndex(of: openChar)!
        let closeChar = closeBrackets[openIdx]
        var closePos = -1
        var nestCount = 0

        for j in (openPos + 1)..<text.length {
            let ch = text.character(at: j)
            if ch == openChar {
                nestCount += 1
            } else if ch == closeChar {
                if nestCount == 0 {
                    closePos = j
                    break
                }
                nestCount -= 1
            }
        }

        guard closePos >= 0 else { return }

        // Select content between brackets (excluding the brackets themselves)
        let innerRange = NSRange(location: openPos + 1, length: closePos - openPos - 1)
        textView.setSelectedRange(innerRange)
        textView.scrollRangeToVisible(innerRange)
    }

    // MARK: - Select Next Occurrence (⌘D)

    @objc func selectNextOccurrence(_ sender: Any?) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let sel = textView.selectedRange()
        let selectedText: String

        if sel.length > 0 {
            selectedText = text.substring(with: sel)
        } else {
            // First press: select the word under cursor
            let wordRange = wordRangeAtIndex(min(sel.location, text.length), in: text)
            guard wordRange.length > 0 else { return }
            textView.setSelectedRange(wordRange)
            return
        }

        // Search forward from end of current selection, wrapping around
        let afterSel = NSMaxRange(sel)
        var searchRange = NSRange(location: afterSel, length: text.length - afterSel)
        var found = text.range(of: selectedText, options: .literal, range: searchRange)

        // Wrap around
        if found.location == NSNotFound {
            searchRange = NSRange(location: 0, length: sel.location)
            found = text.range(of: selectedText, options: .literal, range: searchRange)
        }

        guard found.location != NSNotFound else { return }

        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)

        // Populate find pasteboard
        let pb = NSPasteboard(name: .find)
        pb.clearContents()
        pb.setString(selectedText, forType: .string)
    }

    // MARK: - Delete Line (⌃⇧K)

    @objc func deleteLine(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)

        if textView.shouldChangeText(in: lineRange, replacementString: "") {
            ts.deleteCharacters(in: lineRange)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(lineRange.location, ts.length), length: 0))
        }
    }

    // MARK: - Insert Line Above/Below

    @objc func insertLineAbove(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)

        // Extract leading whitespace from current line
        let lineText = text.substring(with: lineRange)
        var indent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" { indent.append(ch) }
            else { break }
        }

        let insertText = indent + "\n"
        let insertPoint = lineRange.location

        if textView.shouldChangeText(in: NSRange(location: insertPoint, length: 0), replacementString: insertText) {
            ts.insert(NSAttributedString(string: insertText, attributes: [
                .font: editorFont,
                .foregroundColor: theme.foreground,
            ]), at: insertPoint)
            textView.didChangeText()
            // Place cursor at end of indent on the new line
            textView.setSelectedRange(NSRange(location: insertPoint + indent.count, length: 0))
        }
    }

    @objc func insertLineBelow(_ sender: Any? = nil) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()
        let lineRange = text.lineRange(for: sel)

        // Extract leading whitespace from current line
        let lineText = text.substring(with: lineRange)
        var indent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" { indent.append(ch) }
            else { break }
        }

        let insertText = "\n" + indent
        let insertPoint = NSMaxRange(lineRange) - (lineText.hasSuffix("\n") ? 1 : 0)

        if textView.shouldChangeText(in: NSRange(location: insertPoint, length: 0), replacementString: insertText) {
            ts.insert(NSAttributedString(string: insertText, attributes: [
                .font: editorFont,
                .foregroundColor: theme.foreground,
            ]), at: insertPoint)
            textView.didChangeText()
            // Place cursor at end of indent on the new line
            textView.setSelectedRange(NSRange(location: insertPoint + insertText.count, length: 0))
        }
    }

    // MARK: - Sort Lines

    func sortLines() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()

        // If nothing selected, use entire document
        let range = sel.length > 0 ? text.lineRange(for: sel) : NSRange(location: 0, length: ts.length)
        let linesText = text.substring(with: range)
        var lines = linesText.components(separatedBy: "\n")

        // Remove trailing empty line from the split if present
        if lines.last == "" { lines.removeLast() }

        lines.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let sorted = lines.joined(separator: "\n") + (linesText.hasSuffix("\n") ? "\n" : "")

        if textView.shouldChangeText(in: range, replacementString: sorted) {
            ts.replaceCharacters(in: range, with: sorted)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location, length: (sorted as NSString).length))
        }
    }

    func removeDuplicateLines() {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()

        let range = sel.length > 0 ? text.lineRange(for: sel) : NSRange(location: 0, length: ts.length)
        let linesText = text.substring(with: range)
        var lines = linesText.components(separatedBy: "\n")

        if lines.last == "" { lines.removeLast() }

        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            if seen.insert(line).inserted {
                unique.append(line)
            }
        }

        let result = unique.joined(separator: "\n") + (linesText.hasSuffix("\n") ? "\n" : "")
        if textView.shouldChangeText(in: range, replacementString: result) {
            ts.replaceCharacters(in: range, with: result)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location, length: (result as NSString).length))
        }
    }

    // MARK: - Case Transform

    @objc func transformToUppercase(_ sender: Any?) {
        transformSelection { $0.uppercased() }
    }

    @objc func transformToLowercase(_ sender: Any?) {
        transformSelection { $0.lowercased() }
    }

    @objc func transformToTitleCase(_ sender: Any?) {
        transformSelection { text in
            text.split(separator: " ").map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        }
    }

    private func transformSelection(_ transform: (String) -> String) {
        guard let ts = textView.textStorage else { return }
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return }

        let text = (ts.string as NSString).substring(with: sel)
        let transformed = transform(text)
        guard transformed != text else { return }

        if textView.shouldChangeText(in: sel, replacementString: transformed) {
            ts.replaceCharacters(in: sel, with: transformed)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: sel.location, length: (transformed as NSString).length))
        }
    }

    // MARK: - Signature Help

    private func checkSignatureHelp() {
        guard let doc = document, let lsp = lspClient else { return }
        let text = textView.string as NSString
        let cursorPos = textView.selectedRange().location
        guard cursorPos > 0, cursorPos <= text.length else {
            dismissSignatureHelp()
            return
        }

        let prevChar = text.character(at: cursorPos - 1)
        let isTrigger = prevChar == 0x28 || prevChar == 0x2C // ( or ,

        // Also check if we're still inside parens
        let insideParens = isInsideParentheses(at: cursorPos, in: text)

        guard isTrigger || insideParens else {
            dismissSignatureHelp()
            return
        }

        signatureHelpWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (line, character) = self.characterIndexToLineColumn(cursorPos)
            Task { @MainActor in
                do {
                    guard let help = try await lsp.signatureHelp(url: doc.url, line: line, character: character) else {
                        self.dismissSignatureHelp()
                        return
                    }
                    self.showSignatureHelp(help)
                } catch {
                    self.dismissSignatureHelp()
                }
            }
        }
        signatureHelpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func isInsideParentheses(at pos: Int, in text: NSString) -> Bool {
        var depth = 0
        var i = pos - 1
        while i >= 0 {
            let ch = text.character(at: i)
            if ch == 0x29 { depth += 1 } // )
            else if ch == 0x28 { // (
                if depth == 0 { return true }
                depth -= 1
            }
            // Don't go past current line boundaries for simple check
            if ch == 0x0A { break } // newline
            i -= 1
        }
        return false
    }

    private func showSignatureHelp(_ help: LSPSignatureHelp) {
        guard !help.signatures.isEmpty else {
            dismissSignatureHelp()
            return
        }

        let sig = help.signatures[min(help.activeSignature, help.signatures.count - 1)]

        // Build display string with active parameter highlighted
        var displayText = sig.label
        if let params = sig.parameters, help.activeParameter < params.count {
            let activeParam = params[help.activeParameter]
            displayText = sig.label + "\n\nParameter: \(activeParam.label)"
            if let doc = activeParam.documentation {
                displayText += " — \(doc)"
            }
        }
        if let doc = sig.documentation {
            displayText += "\n\(doc)"
        }

        // Reuse or create popover
        dismissSignatureHelp()

        let vc = NSViewController()
        let label = NSTextField(wrappingLabelWithString: displayText)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        containerView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
        ])
        vc.view = containerView

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = false

        // Position at cursor
        let cursorPos = textView.selectedRange().location
        let glyphIndex = textView.layoutManager?.glyphIndexForCharacter(at: cursorPos) ?? 0
        guard let textContainer = textView.textContainer else { return }
        var rect = textView.layoutManager?.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer) ?? .zero
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        signaturePopover = popover
    }

    private func dismissSignatureHelp() {
        signaturePopover?.close()
        signaturePopover = nil
    }

    // MARK: - Format Document

    @objc func formatDocument(_ sender: Any?) {
        guard let doc = document, let lsp = lspClient else { return }
        Task { @MainActor in
            do {
                let edits = try await lsp.formatDocument(url: doc.url, tabSize: tabWidth)
                guard !edits.isEmpty else { return }
                self.applyTextEdits(edits)
            } catch {
                // Silently fail — formatting not supported by all servers
            }
        }
    }

    // MARK: - Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Standard editing items
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // LSP items
        if lspClient != nil, document != nil {
            menu.addItem(withTitle: "Jump to Definition", action: #selector(jumpToDefinitionAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Find References", action: #selector(findReferences(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Rename Symbol...", action: #selector(renameSymbol(_:)), keyEquivalent: "")

            let codeActionsItem = NSMenuItem(title: "Code Actions", action: nil, keyEquivalent: "")
            let codeActionsSubmenu = NSMenu()
            codeActionsItem.submenu = codeActionsSubmenu

            // Fetch code actions asynchronously and populate when ready
            let placeholder = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            codeActionsSubmenu.addItem(placeholder)

            fetchCodeActionsForMenu(codeActionsSubmenu)
            menu.addItem(codeActionsItem)

            menu.addItem(.separator())
            menu.addItem(withTitle: "Format Document", action: #selector(formatDocument(_:)), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All Occurrences", action: #selector(selectAllOccurrencesAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select Enclosing Brackets", action: #selector(selectEnclosingBrackets(_:)), keyEquivalent: "")

        // Send to Claude
        if textView.selectedRange().length > 0 {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Send to Claude", action: #selector(sendToClaudeAction(_:)), keyEquivalent: "")
        }

        // File actions
        if let doc = document {
            menu.addItem(.separator())

            let copyPathItem = NSMenuItem(title: "Copy File Path", action: #selector(copyFilePath(_:)), keyEquivalent: "")
            copyPathItem.representedObject = doc.url
            menu.addItem(copyPathItem)

            if let root = projectRootURL {
                let copyRelItem = NSMenuItem(title: "Copy Relative Path", action: #selector(copyRelativePath(_:)), keyEquivalent: "")
                copyRelItem.representedObject = (doc.url, root) as AnyObject
                menu.addItem(copyRelItem)
            }

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            revealItem.representedObject = doc.url
            menu.addItem(revealItem)
        }
    }

    @objc private func copyFilePath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func copyRelativePath(_ sender: NSMenuItem) {
        guard let doc = document, let root = projectRootURL else { return }
        let filePath = doc.url.path
        let rootPath = root.path
        let relative = filePath.hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count + 1))
            : filePath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relative, forType: .string)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func sendToClaudeAction(_ sender: Any?) {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return }
        let text = (textView.string as NSString).substring(with: sel)
        let (line, _) = characterIndexToLineColumn(sel.location)
        onSendToClaude?(text, document?.fileName, line + 1)
    }

    @objc private func selectAllOccurrencesAction(_ sender: Any?) {
        selectAllOccurrences()
    }

    @objc private func jumpToDefinitionAction(_ sender: Any?) {
        guard let doc = document, let lsp = lspClient else { return }
        let (line, character) = characterIndexToLineColumn(textView.selectedRange().location)

        Task { @MainActor in
            do {
                let locations = try await lsp.definition(url: doc.url, line: line, character: character)
                guard let loc = locations.first, let url = URL(string: loc.uri) else { return }
                self.onJumpToDefinition?(url, loc.range.start.line, loc.range.start.character)
            } catch {}
        }
    }

    private var pendingCodeActions: [LSPCodeAction] = []

    private func fetchCodeActionsForMenu(_ submenu: NSMenu) {
        guard let doc = document, let lsp = lspClient else { return }
        let sel = textView.selectedRange()
        let (startLine, startChar) = characterIndexToLineColumn(sel.location)
        let (endLine, endChar) = characterIndexToLineColumn(sel.location + sel.length)
        let range = LSPRange(
            start: LSPPosition(line: startLine, character: startChar),
            end: LSPPosition(line: endLine, character: endChar)
        )

        // Pass current diagnostics at this location
        let relevantDiags = diagnostics.filter { diag in
            diag.range.start.line <= endLine && diag.range.end.line >= startLine
        }

        Task { @MainActor in
            do {
                let actions = try await lsp.codeActions(url: doc.url, range: range, diagnostics: relevantDiags)
                self.pendingCodeActions = actions
                submenu.removeAllItems()
                if actions.isEmpty {
                    let none = NSMenuItem(title: "No Actions Available", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    submenu.addItem(none)
                } else {
                    for (idx, action) in actions.enumerated() {
                        let item = NSMenuItem(title: action.title, action: #selector(self.codeActionSelected(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = idx
                        submenu.addItem(item)
                    }
                }
            } catch {
                submenu.removeAllItems()
                let err = NSMenuItem(title: "No Actions Available", action: nil, keyEquivalent: "")
                err.isEnabled = false
                submenu.addItem(err)
            }
        }
    }

    @objc private func codeActionSelected(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < pendingCodeActions.count else { return }
        let action = pendingCodeActions[idx]

        guard let edit = action.edit else { return }
        for (url, edits) in edit.changes {
            if url == document?.url {
                applyTextEdits(edits)
            } else {
                onApplyEdits?(url, edits)
            }
        }
    }

    // MARK: - Scroll to Line

    /// Scrolls to a specific line and column (0-based, LSP convention) and places the cursor there.
    func scrollToLine(_ line: Int, column: Int, selectLength: Int = 0) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let charOffset = lineColumnToCharacterIndex(line: line, column: column)
        let selLen = min(selectLength, text.length - charOffset)
        let selRange = NSRange(location: charOffset, length: max(selLen, 0))
        textView.setSelectedRange(selRange)
        textView.scrollRangeToVisible(selRange)
        // Flash the match or line briefly to draw attention
        if selLen > 0 {
            textView.showFindIndicator(for: selRange)
        } else {
            let lineRange = text.lineRange(for: NSRange(location: charOffset, length: 0))
            textView.showFindIndicator(for: lineRange)
        }
    }

    // MARK: - Position Conversion (cached line offsets)

    /// Build or return the cached array of line-start character offsets.
    /// offsets[i] is the character index where line i begins.
    private var lineStartOffsets: [Int] {
        if let cached = _lineStartOffsets { return cached }
        let text = textView.string as NSString
        var offsets = [0]
        for i in 0..<text.length {
            if text.character(at: i) == 0x0A {
                offsets.append(i + 1)
            }
        }
        _lineStartOffsets = offsets
        return offsets
    }

    /// Invalidate the line offset cache (call on every text change).
    private func invalidateLineCache() {
        _lineStartOffsets = nil
    }

    /// Converts a character index in the text to (line, character) — both 0-based for LSP.
    /// Uses binary search on the cached line offsets for O(log n) performance.
    private func characterIndexToLineColumn(_ index: Int) -> (Int, Int) {
        let offsets = lineStartOffsets
        let safeIndex = min(index, (textView.string as NSString).length)
        // Binary search: find the last offset <= safeIndex
        var lo = 0, hi = offsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= safeIndex {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return (lo, safeIndex - offsets[lo])
    }

    /// Converts a 0-based (line, column) to a character index.
    private func lineColumnToCharacterIndex(line: Int, column: Int) -> Int {
        let offsets = lineStartOffsets
        guard line < offsets.count else {
            return (textView.string as NSString).length
        }
        return min(offsets[line] + column, (textView.string as NSString).length)
    }

    // MARK: - Code Folding

    /// Tracks folded regions as (startLine, endLine, originalText) for unfold restoration
    private(set) var foldedRegions: [(startLine: Int, endLine: Int)] = []

    /// Detect lines that start foldable blocks (ending with `{`)
    func updateFoldableLines() {
        let text = textView.string as NSString
        guard text.length > 0 else {
            gutterView.foldableLines = []
            return
        }

        let offsets = lineStartOffsets
        var foldable = Set<Int>()

        for i in 0..<offsets.count {
            let lineStart = offsets[i]
            let lineEnd = (i + 1 < offsets.count) ? offsets[i + 1] - 1 : text.length
            guard lineEnd > lineStart else { continue }

            // Find last non-whitespace character on the line
            var lastNonSpace = lineEnd - 1
            while lastNonSpace >= lineStart {
                let c = text.character(at: lastNonSpace)
                if c != 0x20 && c != 0x09 { break } // skip space and tab
                lastNonSpace -= 1
            }
            guard lastNonSpace >= lineStart && text.character(at: lastNonSpace) == 0x7B else { continue } // '{'

            // Find first non-whitespace character on the line
            var firstNonSpace = lineStart
            while firstNonSpace < lineEnd {
                let c = text.character(at: firstNonSpace)
                if c != 0x20 && c != 0x09 { break }
                firstNonSpace += 1
            }
            guard firstNonSpace < lineEnd else { continue }

            // Skip comment lines
            let firstChar = text.character(at: firstNonSpace)
            if firstChar == 0x2F && firstNonSpace + 1 < lineEnd && text.character(at: firstNonSpace + 1) == 0x2F {
                continue // "//"
            }
            if firstChar == 0x2A { continue } // "*"

            foldable.insert(i)
        }

        gutterView.foldableLines = foldable
    }

    /// Fold/unfold at the current cursor line
    @objc func foldAtCursor(_ sender: Any?) {
        let (line, _) = characterIndexToLineColumn(textView.selectedRange().location)
        if gutterView.foldableLines.contains(line) && !gutterView.foldedLines.contains(line) {
            fold(at: line)
        }
    }

    @objc func unfoldAtCursor(_ sender: Any?) {
        let (line, _) = characterIndexToLineColumn(textView.selectedRange().location)
        if gutterView.foldedLines.contains(line) {
            unfold(at: line)
        }
    }

    /// Toggle fold/unfold at a given 0-indexed line
    func toggleFold(at line: Int) {
        if gutterView.foldedLines.contains(line) {
            unfold(at: line)
        } else {
            fold(at: line)
        }
    }

    private func fold(at startLine: Int) {
        let text = textView.string as NSString
        let offsets = lineStartOffsets
        guard startLine < offsets.count else { return }

        // Find matching closing brace by scanning characters
        var braceCount = 0
        var endLine = startLine
        let totalLines = offsets.count

        for i in startLine..<totalLines {
            let lineStart = offsets[i]
            let lineEnd = (i + 1 < totalLines) ? offsets[i + 1] - 1 : text.length
            for j in lineStart..<lineEnd {
                let ch = text.character(at: j)
                if ch == 0x7B { braceCount += 1 }      // '{'
                else if ch == 0x7D { braceCount -= 1 }  // '}'
            }
            if braceCount == 0 && i > startLine {
                endLine = i
                break
            }
        }

        guard endLine > startLine else { return }

        // Calculate the range to fold (from end of startLine to end of endLine)
        let foldStart: Int
        if startLine + 1 < offsets.count {
            foldStart = offsets[startLine + 1] - 1  // newline at end of startLine
        } else {
            return
        }
        let foldEnd: Int
        if endLine + 1 < offsets.count {
            foldEnd = offsets[endLine + 1] - 1  // end of endLine (before its newline)
        } else {
            foldEnd = text.length
        }

        let foldRange = NSRange(location: foldStart, length: foldEnd - foldStart)
        guard foldRange.length > 0 && foldRange.location + foldRange.length <= text.length else { return }

        // Replace folded content with a placeholder
        let placeholder = " ... }"
        if textView.shouldChangeText(in: foldRange, replacementString: placeholder) {
            textView.textStorage?.replaceCharacters(in: foldRange, with: placeholder)
            textView.didChangeText()
        }

        gutterView.foldedLines.insert(startLine)
        updateFoldableLines()
        gutterView.needsDisplay = true
    }

    private func unfold(at line: Int) {
        // Unfortunately, once text is replaced, we can't restore the original
        // without an undo. Just trigger undo to unfold.
        textView.undoManager?.undo()
        gutterView.foldedLines.remove(line)
        updateFoldableLines()
        gutterView.needsDisplay = true
    }
}

// MARK: - ForgeTextView (smart paste)

/// NSTextView subclass that provides smart paste with automatic indentation adjustment.
class ForgeTextView: NSTextView {

    override func paste(_ sender: Any?) {
        guard let pb = NSPasteboard.general.string(forType: .string),
              pb.contains("\n") else {
            // Single-line paste — use default behavior
            super.paste(sender)
            return
        }

        // Get the indentation at the current cursor line
        let text = string as NSString
        let cursor = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = text.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))

        var targetIndent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" {
                targetIndent.append(ch)
            } else {
                break
            }
        }

        // Find the minimum indentation of the pasted text (ignoring empty lines)
        let lines = pb.components(separatedBy: "\n")
        let nonEmptyLines = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var minIndent = Int.max
        for line in nonEmptyLines {
            var count = 0
            for ch in line {
                if ch == " " { count += 1 }
                else if ch == "\t" { count += Preferences.shared.tabWidth }
                else { break }
            }
            minIndent = min(minIndent, count)
        }
        if minIndent == Int.max { minIndent = 0 }

        // Re-indent: replace pasted text's minimum indent with target indent
        var result = lines[0] // First line stays as-is (inserts at cursor position)
        for line in lines.dropFirst() {
            result += "\n"
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result += line
            } else {
                // Strip the common indent
                var stripped = line
                var removed = 0
                while removed < minIndent, let first = stripped.first {
                    if first == " " {
                        stripped.removeFirst()
                        removed += 1
                    } else if first == "\t" {
                        stripped.removeFirst()
                        removed += Preferences.shared.tabWidth
                    } else {
                        break
                    }
                }
                result += targetIndent + stripped
            }
        }

        insertText(result, replacementRange: selectedRange())
    }
}
