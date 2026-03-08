import AppKit

/// Represents a single command in the palette.
struct PaletteCommand {
    let title: String
    let shortcut: String  // display string like "⌘B"
    let category: String  // "File", "Edit", "View", "Navigate", "Product"
    let action: Selector
    let target: AnyObject?  // nil means use responder chain
}

/// Command Palette (⇧⌘P) — fuzzy search for all available commands.
class CommandPaletteWindowController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allCommands: [PaletteCommand] = []
    private var filteredCommands: [PaletteCommand] = []

    private weak var parentWindow: NSWindow?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true

        super.init(window: panel)

        buildCommands()
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - UI Setup

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Type a command…"
        searchField.font = NSFont.systemFont(ofSize: 18, weight: .light)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.textColor = .white
        searchField.delegate = self
        contentView.addSubview(searchField)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        contentView.addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommandColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Command Registry

    private func buildCommands() {
        allCommands = [
            // File
            PaletteCommand(title: "New File", shortcut: "⌘N", category: "File",
                           action: NSSelectorFromString("newFile:"), target: nil),
            PaletteCommand(title: "Open…", shortcut: "⌘O", category: "File",
                           action: NSSelectorFromString("openDocument:"), target: nil),
            PaletteCommand(title: "Open Quickly", shortcut: "⇧⌘O", category: "File",
                           action: #selector(MainWindowController.showOpenQuickly(_:)), target: nil),
            PaletteCommand(title: "Save", shortcut: "⌘S", category: "File",
                           action: NSSelectorFromString("saveDocument:"), target: nil),
            PaletteCommand(title: "Save All", shortcut: "⌘⌥S", category: "File",
                           action: NSSelectorFromString("saveAllDocuments:"), target: nil),
            PaletteCommand(title: "Close Tab", shortcut: "⌘W", category: "File",
                           action: #selector(MainWindowController.closeCurrentTab(_:)), target: nil),

            // Edit
            PaletteCommand(title: "Toggle Comment", shortcut: "⌘/", category: "Edit",
                           action: #selector(EditorContainerViewController.toggleComment(_:)), target: nil),
            PaletteCommand(title: "Re-Indent", shortcut: "⌃I", category: "Edit",
                           action: #selector(EditorContainerViewController.reindentSelection(_:)), target: nil),
            PaletteCommand(title: "Go to Line…", shortcut: "⌘L", category: "Edit",
                           action: #selector(EditorContainerViewController.goToLine(_:)), target: nil),
            PaletteCommand(title: "Edit All in Scope (Rename)", shortcut: "⌃⌘E", category: "Edit",
                           action: #selector(EditorContainerViewController.renameSymbol(_:)), target: nil),
            PaletteCommand(title: "Sort Lines", shortcut: "", category: "Edit",
                           action: #selector(EditorContainerViewController.sortLines(_:)), target: nil),
            PaletteCommand(title: "Remove Duplicate Lines", shortcut: "", category: "Edit",
                           action: #selector(EditorContainerViewController.removeDuplicateLines(_:)), target: nil),
            PaletteCommand(title: "Format Document", shortcut: "⌃⇧I", category: "Edit",
                           action: #selector(EditorContainerViewController.formatDocument(_:)), target: nil),
            PaletteCommand(title: "Move Line Up", shortcut: "⌘⌥[", category: "Edit",
                           action: #selector(EditorContainerViewController.moveLineUp(_:)), target: nil),
            PaletteCommand(title: "Move Line Down", shortcut: "⌘⌥]", category: "Edit",
                           action: #selector(EditorContainerViewController.moveLineDown(_:)), target: nil),
            PaletteCommand(title: "Duplicate Line", shortcut: "⌘⇧D", category: "Edit",
                           action: #selector(EditorContainerViewController.duplicateLine(_:)), target: nil),
            PaletteCommand(title: "Delete Line", shortcut: "⌃⇧K", category: "Edit",
                           action: #selector(EditorContainerViewController.deleteLine(_:)), target: nil),
            PaletteCommand(title: "Join Lines", shortcut: "⌃J", category: "Edit",
                           action: #selector(EditorContainerViewController.joinLines(_:)), target: nil),
            PaletteCommand(title: "Select Next Occurrence", shortcut: "⌘D", category: "Edit",
                           action: #selector(EditorContainerViewController.selectNextOccurrence(_:)), target: nil),
            PaletteCommand(title: "Select Enclosing Brackets", shortcut: "", category: "Edit",
                           action: #selector(EditorContainerViewController.selectEnclosingBrackets(_:)), target: nil),
            PaletteCommand(title: "Send to Claude", shortcut: "⌃⇧C", category: "Edit",
                           action: #selector(EditorContainerViewController.sendToClaude(_:)), target: nil),
            PaletteCommand(title: "Make Uppercase", shortcut: "⌃⇧U", category: "Edit",
                           action: #selector(EditorContainerViewController.transformToUppercase(_:)), target: nil),
            PaletteCommand(title: "Make Lowercase", shortcut: "⌃U", category: "Edit",
                           action: #selector(EditorContainerViewController.transformToLowercase(_:)), target: nil),
            PaletteCommand(title: "Title Case", shortcut: "", category: "Edit",
                           action: #selector(EditorContainerViewController.transformToTitleCase(_:)), target: nil),
            PaletteCommand(title: "Find in Project", shortcut: "⌘⇧F", category: "Edit",
                           action: #selector(MainSplitViewController.findInProject(_:)), target: nil),
            PaletteCommand(title: "Find All References", shortcut: "", category: "Edit",
                           action: #selector(EditorContainerViewController.findReferences(_:)), target: nil),

            // View
            PaletteCommand(title: "Toggle Navigator", shortcut: "⌘0", category: "View",
                           action: #selector(MainSplitViewController.toggleNavigator(_:)), target: nil),
            PaletteCommand(title: "Toggle Inspector", shortcut: "⌘⌥0", category: "View",
                           action: #selector(MainSplitViewController.toggleInspector(_:)), target: nil),
            PaletteCommand(title: "Toggle Bottom Panel", shortcut: "⌘⇧Y", category: "View",
                           action: #selector(MainSplitViewController.toggleBottomPanel(_:)), target: nil),
            PaletteCommand(title: "Toggle Minimap", shortcut: "⌃⌘M", category: "View",
                           action: #selector(EditorContainerViewController.toggleMinimap(_:)), target: nil),
            PaletteCommand(title: "Toggle Word Wrap", shortcut: "⌘⌥L", category: "View",
                           action: #selector(EditorContainerViewController.toggleWordWrap(_:)), target: nil),
            PaletteCommand(title: "Toggle Invisible Characters", shortcut: "⌘⌥I", category: "View",
                           action: #selector(EditorContainerViewController.toggleInvisibles(_:)), target: nil),
            PaletteCommand(title: "Toggle Bracket Colorization", shortcut: "", category: "View",
                           action: #selector(EditorContainerViewController.toggleBracketColorization(_:)), target: nil),
            PaletteCommand(title: "Pin/Unpin Current Tab", shortcut: "", category: "View",
                           action: #selector(EditorContainerViewController.togglePinCurrentTab(_:)), target: nil),
            PaletteCommand(title: "Zoom In", shortcut: "⌘+", category: "View",
                           action: #selector(EditorContainerViewController.increaseFontSize(_:)), target: nil),
            PaletteCommand(title: "Zoom Out", shortcut: "⌘-", category: "View",
                           action: #selector(EditorContainerViewController.decreaseFontSize(_:)), target: nil),
            PaletteCommand(title: "Reset Zoom", shortcut: "⌘⌥0", category: "View",
                           action: #selector(EditorContainerViewController.resetFontSize(_:)), target: nil),
            PaletteCommand(title: "Fold", shortcut: "⌘⌥←", category: "View",
                           action: #selector(EditorContainerViewController.foldAtCursor(_:)), target: nil),
            PaletteCommand(title: "Unfold", shortcut: "⌘⌥→", category: "View",
                           action: #selector(EditorContainerViewController.unfoldAtCursor(_:)), target: nil),
            PaletteCommand(title: "Source Control", shortcut: "⌃⌘2", category: "View",
                           action: #selector(MainSplitViewController.showSourceControlAction(_:)), target: nil),

            // Navigate
            PaletteCommand(title: "Previous Tab", shortcut: "⌘⇧[", category: "Navigate",
                           action: #selector(MainWindowController.selectPreviousTab(_:)), target: nil),
            PaletteCommand(title: "Next Tab", shortcut: "⌘⇧]", category: "Navigate",
                           action: #selector(MainWindowController.selectNextTab(_:)), target: nil),
            PaletteCommand(title: "Reopen Closed Tab", shortcut: "⌘⇧T", category: "Navigate",
                           action: #selector(MainWindowController.reopenLastTab(_:)), target: nil),
            PaletteCommand(title: "Reveal in Navigator", shortcut: "⌘⇧J", category: "Navigate",
                           action: #selector(MainSplitViewController.revealInNavigator(_:)), target: nil),
            PaletteCommand(title: "Go Back", shortcut: "⌃⌘←", category: "Navigate",
                           action: #selector(MainWindowController.goBack(_:)), target: nil),
            PaletteCommand(title: "Go Forward", shortcut: "⌃⌘→", category: "Navigate",
                           action: #selector(MainWindowController.goForward(_:)), target: nil),
            PaletteCommand(title: "Document Symbols", shortcut: "⌃6", category: "Navigate",
                           action: #selector(EditorContainerViewController.showDocumentSymbols(_:)), target: nil),
            PaletteCommand(title: "Jump to Next Issue", shortcut: "⌃⌘'", category: "Navigate",
                           action: #selector(EditorContainerViewController.jumpToNextIssue(_:)), target: nil),
            PaletteCommand(title: "Jump to Previous Issue", shortcut: "⌃⌘\"", category: "Navigate",
                           action: #selector(EditorContainerViewController.jumpToPreviousIssue(_:)), target: nil),
            PaletteCommand(title: "Focus Editor", shortcut: "Esc", category: "Navigate",
                           action: #selector(MainWindowController.focusEditor(_:)), target: nil),

            // Product
            PaletteCommand(title: "Build", shortcut: "⌘B", category: "Product",
                           action: #selector(MainWindowController.buildProject(_:)), target: nil),
            PaletteCommand(title: "Run", shortcut: "⌘R", category: "Product",
                           action: #selector(MainWindowController.runProject(_:)), target: nil),
            PaletteCommand(title: "Clean Build", shortcut: "⌘⇧K", category: "Product",
                           action: #selector(MainWindowController.cleanBuild(_:)), target: nil),
            PaletteCommand(title: "Stop", shortcut: "⌘.", category: "Product",
                           action: #selector(MainWindowController.stopBuild(_:)), target: nil),

            // App
            PaletteCommand(title: "Settings…", shortcut: "⌘,", category: "App",
                           action: NSSelectorFromString("showPreferences:"), target: nil),
            PaletteCommand(title: "Keyboard Shortcuts", shortcut: "", category: "App",
                           action: NSSelectorFromString("showKeyboardShortcuts:"), target: nil),
        ]
    }

    // MARK: - Show/Dismiss

    func showInWindow(_ parentWindow: NSWindow) {
        guard let panel = window else { return }
        self.parentWindow = parentWindow

        let parentFrame = parentWindow.frame
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 360
        let x = parentFrame.origin.x + (parentFrame.width - panelWidth) / 2
        let y = parentFrame.origin.y + parentFrame.height - panelHeight - 80
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        searchField.stringValue = ""
        filteredCommands = allCommands
        tableView.reloadData()

        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func dismiss() {
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: - Search

    private func updateSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            filteredCommands = allCommands
        } else {
            struct Scored {
                let command: PaletteCommand
                let score: Int
            }

            let scored: [Scored] = allCommands.compactMap { cmd in
                // Match against title
                if let result = FuzzyMatch.match(pattern: query, candidate: cmd.title) {
                    return Scored(command: cmd, score: result.score)
                }
                // Also match against category + title
                let full = "\(cmd.category) \(cmd.title)"
                if let result = FuzzyMatch.match(pattern: query, candidate: full) {
                    return Scored(command: cmd, score: result.score - 20)
                }
                return nil
            }

            filteredCommands = scored.sorted { $0.score > $1.score }.map(\.command)
        }

        tableView.reloadData()

        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let count = filteredCommands.count
            guard count > 0 else { return true }
            let newRow = min(tableView.selectedRow + 1, count - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let newRow = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirmSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCommands.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredCommands.count else { return nil }
        let cmd = filteredCommands[row]

        let cellID = NSUserInterfaceItemIdentifier("CommandPaletteCell")
        let shortcutTag = 101
        let categoryTag = 102

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.textColor = NSColor(white: 0.9, alpha: 1.0)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            let categoryLabel = NSTextField(labelWithString: "")
            categoryLabel.translatesAutoresizingMaskIntoConstraints = false
            categoryLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            categoryLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            categoryLabel.lineBreakMode = .byTruncatingTail
            categoryLabel.tag = categoryTag
            cell.addSubview(categoryLabel)

            let shortcutLabel = NSTextField(labelWithString: "")
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcutLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            shortcutLabel.alignment = .right
            shortcutLabel.tag = shortcutTag
            cell.addSubview(shortcutLabel)

            NSLayoutConstraint.activate([
                categoryLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                categoryLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                categoryLabel.widthAnchor.constraint(equalToConstant: 56),

                textField.leadingAnchor.constraint(equalTo: categoryLabel.trailingAnchor, constant: 4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                shortcutLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                shortcutLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 8),
            ])

            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        cell.textField?.stringValue = cmd.title
        if let shortcutLabel = cell.viewWithTag(shortcutTag) as? NSTextField {
            shortcutLabel.stringValue = cmd.shortcut
        }
        if let categoryLabel = cell.viewWithTag(categoryTag) as? NSTextField {
            categoryLabel.stringValue = cmd.category
        }

        return cell
    }

    // MARK: - Selection

    @objc private func tableDoubleClicked(_ sender: Any?) {
        confirmSelection()
    }

    private func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCommands.count else { return }
        let cmd = filteredCommands[row]
        dismiss()

        // Send the action through the responder chain
        DispatchQueue.main.async {
            NSApp.sendAction(cmd.action, to: cmd.target, from: nil)
        }
    }
}
