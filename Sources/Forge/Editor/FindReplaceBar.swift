import AppKit

/// Custom find/replace bar that overlays the top of the editor.
/// Provides search with highlighting, case/regex toggles, and replace functionality.
class FindReplaceBar: NSView {

    /// Called when the user types in the search field — provides search term and options
    var onSearch: ((String, SearchOptions) -> [NSRange])?
    /// Called to navigate to next/previous match
    var onNavigate: ((NavigateDirection) -> Void)?
    /// Called to replace the current match with replacement text
    var onReplace: ((String) -> Void)?
    /// Called to replace all matches
    var onReplaceAll: ((String) -> Void)?
    /// Called when the bar is dismissed
    var onDismiss: (() -> Void)?
    /// Called when bar height changes (replace toggled)
    var onHeightChange: ((CGFloat) -> Void)?

    struct SearchOptions {
        var caseSensitive: Bool
        var wholeWord: Bool
        var regex: Bool
    }

    enum NavigateDirection {
        case next, previous
    }

    // MARK: - UI Components

    private let searchField = NSTextField()
    private let replaceField = NSTextField()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let caseSensitiveButton = NSButton()
    private let wholeWordButton = NSButton()
    private let regexButton = NSButton()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let closeButton = NSButton()
    private let expandReplaceButton = NSButton()

    private let searchRow = NSView()
    private let replaceRow = NSView()

    private(set) var isReplaceVisible = false
    private var currentMatches: [NSRange] = []
    private var currentMatchIndex: Int = -1

    // MARK: - State

    private var caseSensitive = false
    private var wholeWord = false
    private var useRegex = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 0.97).cgColor

        // Bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 0.30, alpha: 1.0).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Search row
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchRow)

        // Replace row
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.isHidden = true
        addSubview(replaceRow)

        // --- Search field ---
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.delegate = self
        searchRow.addSubview(searchField)

        // --- Match count label ---
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        matchCountLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        matchCountLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        matchCountLabel.alignment = .right
        matchCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        searchRow.addSubview(matchCountLabel)

        // --- Toggle buttons ---
        configureToggle(caseSensitiveButton, title: "Aa", tooltip: "Match Case")
        caseSensitiveButton.target = self
        caseSensitiveButton.action = #selector(toggleCaseSensitive)
        searchRow.addSubview(caseSensitiveButton)

        configureToggle(wholeWordButton, title: "W", tooltip: "Whole Word")
        wholeWordButton.target = self
        wholeWordButton.action = #selector(toggleWholeWord)
        searchRow.addSubview(wholeWordButton)

        configureToggle(regexButton, title: ".*", tooltip: "Regular Expression")
        regexButton.target = self
        regexButton.action = #selector(toggleRegex)
        searchRow.addSubview(regexButton)

        // --- Navigation buttons ---
        configureNavButton(prevButton, symbolName: "chevron.up", tooltip: "Previous Match (⌘⇧G)", action: #selector(prevMatch))
        searchRow.addSubview(prevButton)

        configureNavButton(nextButton, symbolName: "chevron.down", tooltip: "Next Match (⌘G)", action: #selector(nextMatch))
        searchRow.addSubview(nextButton)

        // --- Close button ---
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.toolTip = "Close (Esc)"
        searchRow.addSubview(closeButton)

        // --- Expand replace button ---
        expandReplaceButton.translatesAutoresizingMaskIntoConstraints = false
        expandReplaceButton.bezelStyle = .inline
        expandReplaceButton.isBordered = false
        expandReplaceButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle Replace")
        expandReplaceButton.imageScaling = .scaleProportionallyDown
        expandReplaceButton.target = self
        expandReplaceButton.action = #selector(toggleReplace)
        expandReplaceButton.toolTip = "Toggle Replace"
        searchRow.addSubview(expandReplaceButton)

        // --- Replace field ---
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.placeholderString = "Replace"
        replaceField.font = NSFont.systemFont(ofSize: 12)
        replaceField.focusRingType = .none
        replaceField.bezelStyle = .roundedBezel
        replaceRow.addSubview(replaceField)

        // --- Replace button ---
        replaceButton.translatesAutoresizingMaskIntoConstraints = false
        replaceButton.bezelStyle = .inline
        replaceButton.isBordered = false
        replaceButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Replace")
        replaceButton.imageScaling = .scaleProportionallyDown
        replaceButton.target = self
        replaceButton.action = #selector(replaceAction)
        replaceButton.toolTip = "Replace (⌘⇧1)"
        replaceRow.addSubview(replaceButton)

        // --- Replace all button ---
        replaceAllButton.translatesAutoresizingMaskIntoConstraints = false
        replaceAllButton.bezelStyle = .inline
        replaceAllButton.isBordered = false
        replaceAllButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right.square", accessibilityDescription: "Replace All")
        replaceAllButton.imageScaling = .scaleProportionallyDown
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllAction)
        replaceAllButton.toolTip = "Replace All (⌘⌥Enter)"
        replaceRow.addSubview(replaceAllButton)

        // Layout
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            searchRow.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            searchRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            searchRow.heightAnchor.constraint(equalToConstant: 24),

            replaceRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4),
            replaceRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            replaceRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            replaceRow.heightAnchor.constraint(equalToConstant: 24),

            // Search row layout
            expandReplaceButton.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            expandReplaceButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            expandReplaceButton.widthAnchor.constraint(equalToConstant: 16),
            expandReplaceButton.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: expandReplaceButton.trailingAnchor, constant: 4),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            matchCountLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            matchCountLabel.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            matchCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),

            caseSensitiveButton.leadingAnchor.constraint(equalTo: matchCountLabel.trailingAnchor, constant: 4),
            caseSensitiveButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            wholeWordButton.leadingAnchor.constraint(equalTo: caseSensitiveButton.trailingAnchor, constant: 2),
            wholeWordButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            regexButton.leadingAnchor.constraint(equalTo: wholeWordButton.trailingAnchor, constant: 2),
            regexButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: regexButton.trailingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: nextButton.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // Replace row layout
            replaceField.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            replaceField.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            replaceField.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),

            replaceButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 6),
            replaceButton.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
            replaceButton.widthAnchor.constraint(equalToConstant: 22),
            replaceButton.heightAnchor.constraint(equalToConstant: 22),

            replaceAllButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor, constant: 2),
            replaceAllButton.centerYAnchor.constraint(equalTo: replaceRow.centerYAnchor),
            replaceAllButton.widthAnchor.constraint(equalToConstant: 22),
            replaceAllButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func configureToggle(_ button: NSButton, title: String, tooltip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.setButtonType(.toggle)
        button.title = title
        button.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        button.toolTip = tooltip
        button.isBordered = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func configureNavButton(_ button: NSButton, symbolName: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.toolTip = tooltip
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// Returns the total height of the bar based on whether replace is visible
    var barHeight: CGFloat {
        isReplaceVisible ? 60 : 32
    }

    // MARK: - Public API

    /// Show the find bar, optionally with replace visible
    func show(withReplace: Bool = false, initialText: String? = nil) {
        isHidden = false
        isReplaceVisible = withReplace
        replaceRow.isHidden = !withReplace
        updateExpandIcon()

        if let text = initialText, !text.isEmpty {
            searchField.stringValue = text
        }

        // Trigger search with current field value
        performSearch()

        // Focus and select all text in the search field
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Hide the bar and clear highlights
    func hide() {
        isHidden = true
        currentMatches = []
        currentMatchIndex = -1
        matchCountLabel.stringValue = ""
        onDismiss?()
    }

    /// Update match results (called externally when text changes while find bar is open)
    func refreshSearch() {
        if !isHidden && !searchField.stringValue.isEmpty {
            performSearch()
        }
    }

    /// Select all text in the search field (for ⌘F when already visible)
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    // MARK: - Actions

    @objc private func searchFieldAction(_ sender: Any?) {
        // Enter key pressed in search field — go to next match
        if !currentMatches.isEmpty {
            onNavigate?(.next)
            advanceMatchIndex(forward: true)
        }
    }

    @objc private func prevMatch(_ sender: Any?) {
        onNavigate?(.previous)
        advanceMatchIndex(forward: false)
    }

    @objc private func nextMatch(_ sender: Any?) {
        onNavigate?(.next)
        advanceMatchIndex(forward: true)
    }

    @objc private func toggleCaseSensitive(_ sender: Any?) {
        caseSensitive = caseSensitiveButton.state == .on
        performSearch()
    }

    @objc private func toggleWholeWord(_ sender: Any?) {
        wholeWord = wholeWordButton.state == .on
        performSearch()
    }

    @objc private func toggleRegex(_ sender: Any?) {
        useRegex = regexButton.state == .on
        performSearch()
    }

    @objc private func replaceAction(_ sender: Any?) {
        onReplace?(replaceField.stringValue)
        // Re-search to update match count
        performSearch()
    }

    @objc private func replaceAllAction(_ sender: Any?) {
        onReplaceAll?(replaceField.stringValue)
        performSearch()
    }

    @objc private func dismiss(_ sender: Any?) {
        hide()
    }

    @objc private func toggleReplace(_ sender: Any?) {
        isReplaceVisible.toggle()
        replaceRow.isHidden = !isReplaceVisible
        updateExpandIcon()
        onHeightChange?(barHeight)
    }

    private func updateExpandIcon() {
        let name = isReplaceVisible ? "chevron.down" : "chevron.right"
        expandReplaceButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Toggle Replace")
    }

    // MARK: - Search Logic

    private func performSearch() {
        let query = searchField.stringValue
        guard !query.isEmpty else {
            currentMatches = []
            currentMatchIndex = -1
            matchCountLabel.stringValue = ""
            // Clear highlights by calling with empty
            _ = onSearch?("", SearchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord, regex: useRegex))
            return
        }

        let options = SearchOptions(caseSensitive: caseSensitive, wholeWord: wholeWord, regex: useRegex)
        let matches = onSearch?(query, options) ?? []
        currentMatches = matches
        currentMatchIndex = matches.isEmpty ? -1 : 0

        updateMatchCountLabel()
    }

    private func advanceMatchIndex(forward: Bool) {
        guard !currentMatches.isEmpty else { return }
        if forward {
            currentMatchIndex = (currentMatchIndex + 1) % currentMatches.count
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + currentMatches.count) % currentMatches.count
        }
        updateMatchCountLabel()
    }

    /// Update the match index to reflect the current cursor position
    func updateCurrentMatchIndex(cursorLocation: Int) {
        guard !currentMatches.isEmpty else {
            currentMatchIndex = -1
            updateMatchCountLabel()
            return
        }
        // Find the match closest to cursor
        for (i, range) in currentMatches.enumerated() {
            if range.location >= cursorLocation {
                currentMatchIndex = i
                updateMatchCountLabel()
                return
            }
        }
        currentMatchIndex = 0
        updateMatchCountLabel()
    }

    private func updateMatchCountLabel() {
        if currentMatches.isEmpty {
            matchCountLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No results"
            matchCountLabel.textColor = searchField.stringValue.isEmpty
                ? NSColor(white: 0.55, alpha: 1.0)
                : NSColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 1.0)
        } else {
            matchCountLabel.stringValue = "\(currentMatchIndex + 1) of \(currentMatches.count)"
            matchCountLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            hide()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        hide()
    }
}

// MARK: - NSTextFieldDelegate

extension FindReplaceBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === searchField {
            performSearch()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === searchField {
                // Enter in search field → next match
                if !currentMatches.isEmpty {
                    onNavigate?(.next)
                    advanceMatchIndex(forward: true)
                }
                return true
            }
            if control === replaceField {
                // Enter in replace field → replace current
                onReplace?(replaceField.stringValue)
                performSearch()
                return true
            }
        }
        return false
    }
}
