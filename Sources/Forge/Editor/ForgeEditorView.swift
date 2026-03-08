import AppKit

/// Manages the editor text view, gutter, syntax highlighting, and LSP integration.
/// This is NOT a view subclass — it manages views that are added to a parent container.
class ForgeEditorManager: NSObject, NSTextViewDelegate {

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

    /// Called when cursor position changes: (line, column, totalLines)
    var onCursorChange: ((Int, Int, Int) -> Void)?

    /// Minimap view (set externally, updated on scroll/edit)
    weak var minimapView: MinimapView?

    /// Called when user ⌘-clicks to jump to definition: (url, line, column)
    var onJumpToDefinition: ((URL, Int, Int) -> Void)?

    /// Called when LSP rename produces edits for external files: (url, edits)
    var onApplyEdits: ((URL, [LSPTextEdit]) -> Void)?

    /// Called when "Find All References" finds results: [(url, line, column)]
    var onShowReferences: (([LSPLocation]) -> Void)?

    let theme: Theme = .xcodeDefaultDark
    private(set) var fontSize: CGFloat = 13
    let gutterWidth: CGFloat = 44
    let tabWidth: Int = 4

    /// Tracks the previously highlighted line range so we can clear it
    private var currentLineRange: NSRange?

    /// Tracks occurrence highlight ranges so we can clear them
    private var occurrenceHighlightRanges: [NSRange] = []

    /// Tracks bracket match highlight range
    private var bracketMatchRange: NSRange?

    /// Debounce for occurrence highlighting
    private var occurrenceWorkItem: DispatchWorkItem?

    /// Completion popup
    private var completionWindow: CompletionWindow?

    /// Event monitor for ⌘-click and ⌥-click
    private var clickMonitor: Any?

    /// Hover popup
    private var hoverPopover: NSPopover?

    /// Tracks whether completion was auto-triggered (vs explicit ⌃Space)
    private var completionPrefix: String = ""

    override init() {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView

        self.scrollView = sv
        self.textView = tv

        super.init()

        textView.delegate = self
        configureTextView()
        configureGutter()
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
                                 "js", "ts", "c", "h", "cpp", "m", "mm", "css", "html",
                                 "xml", "sh", "bash", "zsh", "rb", "go", "rs", "toml"]
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

    // MARK: - Text Change Handling (NSTextDelegate)

    private var completionTriggerWorkItem: DispatchWorkItem?

    func textDidChange(_ notification: Notification) {
        document?.isModified = true
        gutterView.needsDisplay = true
        minimapView?.needsDisplay = true

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
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        gutterView.needsDisplay = true
        minimapView?.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
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
        guard let ts = textView.textStorage else { return }
        let selectedRange = textView.selectedRange()

        if let highlighter = highlighter {
            let text = ts.string
            highlighter.parse(text)
            highlighter.highlight(ts)
        } else if let simple = simpleHighlighter {
            simple.highlight(ts)
        }

        applyDiagnosticUnderlines()
        updateCurrentLineHighlight()
        textView.setSelectedRange(selectedRange)
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
        applyFontSize()
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - 1, 8)
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = 13
        applyFontSize()
    }

    private func applyFontSize() {
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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

        // Skip over closing bracket if it matches what's being typed
        if replacement == ")" || replacement == "]" || replacement == "}" {
            let text = textView.string as NSString
            if affectedCharRange.location < text.length {
                let nextChar = text.character(at: affectedCharRange.location)
                if String(Character(UnicodeScalar(nextChar)!)) == replacement {
                    textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
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
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") {
            indent += String(repeating: " ", count: tabWidth)
        }

        textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
    }

    // MARK: - Toggle Comment (⌘/)

    @objc func toggleComment(_ sender: Any?) {
        guard let ts = textView.textStorage else { return }
        let text = ts.string as NSString
        let sel = textView.selectedRange()

        let lineRange = text.lineRange(for: sel)
        let linesText = text.substring(with: lineRange)
        let lines = linesText.components(separatedBy: "\n")

        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = nonEmptyLines.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }

        var newLines: [String] = []
        for line in lines {
            if allCommented {
                if let range = line.range(of: "// ") {
                    var newLine = line
                    newLine.removeSubrange(range)
                    newLines.append(newLine)
                } else if let range = line.range(of: "//") {
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
                    newLines.append(String(indent) + "// " + rest)
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

    private func handleCompletionOnTextChange() {
        // Check if the character just typed is a completion trigger
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        guard cursor > 0 else {
            completionWindow?.dismiss()
            return
        }

        let ch = text.character(at: cursor - 1)
        let charStr = String(Character(UnicodeScalar(ch)!))

        if charStr == "." {
            // Auto-trigger completion after `.` with a short delay
            completionTriggerWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.triggerCompletion()
            }
            completionTriggerWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else if completionWindow?.isShowing == true {
            // If completion is showing, dismiss on non-identifier characters
            guard let scalar = Unicode.Scalar(ch) else {
                completionWindow?.dismiss()
                return
            }
            if !CharacterSet.alphanumerics.contains(scalar) && scalar != "_" {
                completionWindow?.dismiss()
            }
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
                moveLineUp()
                return true
            } else if event.keyCode == 30 { // ] key
                moveLineDown()
                return true
            }
        }

        // ⌘D → duplicate line
        if mods == [.command] && event.keyCode == 2 { // D key
            duplicateLine()
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

    private func moveLineUp() {
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

    private func moveLineDown() {
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

    private func duplicateLine() {
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
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: theme.foreground,
            ]), at: insertPoint)
            textView.didChangeText()

            // Move cursor to the duplicated line
            let newCursorPos = insertPoint + (sel.location - lineRange.location)
            textView.setSelectedRange(NSRange(location: newCursorPos, length: sel.length))
        }
    }

    // MARK: - Scroll to Line

    /// Scrolls to a specific line and column (0-based, LSP convention) and places the cursor there.
    func scrollToLine(_ line: Int, column: Int) {
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        var currentLine = 0
        var offset = 0
        while currentLine < line && offset < text.length {
            if text.character(at: offset) == 0x0A {
                currentLine += 1
            }
            offset += 1
        }

        let charOffset = min(offset + column, text.length)
        let range = NSRange(location: charOffset, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: NSRange(location: charOffset, length: 0))
    }

    // MARK: - Position Conversion

    /// Converts a character index in the text to (line, character) — both 0-based for LSP.
    private func characterIndexToLineColumn(_ index: Int) -> (Int, Int) {
        let text = textView.string as NSString
        let safeIndex = min(index, text.length)
        var line = 0
        var lastLineStart = 0
        for i in 0..<safeIndex {
            if text.character(at: i) == 0x0A {
                line += 1
                lastLineStart = i + 1
            }
        }
        return (line, safeIndex - lastLineStart)
    }
}
