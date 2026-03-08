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

    /// Called when user ⌘-clicks to jump to definition: (url, line, column)
    var onJumpToDefinition: ((URL, Int, Int) -> Void)?

    let theme: Theme = .xcodeDefaultDark
    let fontSize: CGFloat = 13
    let gutterWidth: CGFloat = 44
    let tabWidth: Int = 4

    /// Tracks the previously highlighted line range so we can clear it
    private var currentLineRange: NSRange?

    /// Completion popup
    private var completionWindow: CompletionWindow?

    /// Event monitor for ⌘-click
    private var clickMonitor: Any?

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
        let ext = doc.fileExtension.lowercased()
        if ext == "swift" {
            highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
            simpleHighlighter = nil
            highlighter?.parse(textView.string)
            if let ts = textView.textStorage {
                highlighter?.highlight(ts)
            }
        } else {
            highlighter = nil
            let supportedExts = ["json", "md", "markdown", "yml", "yaml", "py", "python",
                                 "js", "ts", "c", "h", "cpp", "m"]
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

        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

        gutterView.textView = textView
        gutterView.needsDisplay = true

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
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        gutterView.needsDisplay = true
        notifyCursorPosition()
        updateCurrentLineHighlight()
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

    // MARK: - NSTextViewDelegate (Tab-to-spaces, Auto-indent)

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let spaces = String(repeating: " ", count: tabWidth)
            textView.insertText(spaces, replacementRange: textView.selectedRange())
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

            // Only handle ⌘-click
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option) else {
                return event
            }

            // Check if click is in our text view
            let locationInTextView = self.textView.convert(event.locationInWindow, from: nil)
            guard self.textView.bounds.contains(locationInTextView) else {
                return event
            }

            self.handleJumpToDefinition(at: locationInTextView)
            return nil // consume the event
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
