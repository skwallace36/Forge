import AppKit

protocol OpenQuicklyDelegate: AnyObject {
    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL)
    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL, atLine line: Int, column: Int)
}

extension OpenQuicklyDelegate {
    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL, atLine line: Int, column: Int) {
        openQuickly(controller, didSelectURL: url)
    }
}

/// Modal overlay for ⇧⌘O — fuzzy file search.
class OpenQuicklyWindowController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: OpenQuicklyDelegate?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allFiles: [URL] = []
    private var filteredResults: [(url: URL, match: FuzzyMatch.Result)] = []
    private var symbolResults: [LSPSymbolInformation] = []
    private var pendingLine: Int? // parsed from query:line syntax
    private var isSymbolMode = false
    private var isRecentMode = false
    private var indexingTask: Task<Void, Never>?
    private var symbolSearchTask: Task<Void, Never>?

    /// Recently opened file URLs — shown when query is empty
    var recentFileURLs: [URL] = []

    private let projectRoot: URL
    weak var lspClient: LSPClient?

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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

        setupViews()
        indexFiles(at: projectRoot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Open Quickly — filename or #symbol"
        searchField.font = NSFont.systemFont(ofSize: 18, weight: .light)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.textColor = .white
        searchField.delegate = self
        contentView.addSubview(searchField)

        // Separator
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        contentView.addSubview(separator)

        // Table view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 40
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

    // MARK: - File Indexing

    private func indexFiles(at root: URL) {
        indexingTask = Task { [weak self] in
            let files = await Task.detached {
                Self.collectFiles(at: root)
            }.value

            if Task.isCancelled { return }

            await MainActor.run {
                self?.allFiles = files
            }
        }
    }

    nonisolated private static func collectFiles(at root: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return files }

        let skipDirs: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "node_modules", "Pods"]

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir && skipDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            if !isDir {
                files.append(url)
            }
        }

        return files
    }

    // MARK: - Show/Dismiss

    func showInWindow(_ parentWindow: NSWindow) {
        guard let panel = window else { return }

        // Center above parent
        let parentFrame = parentWindow.frame
        let panelWidth: CGFloat = 600
        let panelHeight: CGFloat = 400
        let x = parentFrame.origin.x + (parentFrame.width - panelWidth) / 2
        let y = parentFrame.origin.y + parentFrame.height - panelHeight - 80
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        searchField.stringValue = ""
        updateSearch() // Shows recent files when query is empty
    }

    func dismiss() {
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: - Search

    private func updateSearch() {
        let query = searchField.stringValue

        // Symbol mode: query starts with #
        if query.hasPrefix("#") {
            isSymbolMode = true
            filteredResults = []
            let symbolQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            if symbolQuery.isEmpty {
                symbolResults = []
                tableView.reloadData()
                return
            }
            searchSymbols(symbolQuery)
            return
        }

        isSymbolMode = false
        symbolResults = []
        symbolSearchTask?.cancel()

        // Parse :line suffix (e.g., "file.swift:42")
        pendingLine = nil
        var searchQuery = query
        if let colonRange = query.range(of: ":", options: .backwards),
           let lineNum = Int(query[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)),
           lineNum > 0 {
            pendingLine = lineNum - 1 // convert to 0-based
            searchQuery = String(query[..<colonRange.lowerBound])
        }

        if searchQuery.isEmpty && pendingLine == nil {
            // Show recent files when query is empty
            isRecentMode = !recentFileURLs.isEmpty
            filteredResults = recentFileURLs.compactMap { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (url: url, match: FuzzyMatch.Result(score: 0, matchedIndices: []))
            }
        } else if searchQuery.isEmpty && pendingLine != nil {
            // Just ":42" — jump to line in current file, handled by confirmSelection
            isRecentMode = false
            filteredResults = []
        } else {
            isRecentMode = false
            let rootPath = projectRoot.standardizedFileURL.path
            filteredResults = allFiles.compactMap { url in
                // Try matching against filename first (higher priority)
                let fileName = url.lastPathComponent
                if let result = FuzzyMatch.match(pattern: searchQuery, candidate: fileName) {
                    return (url: url, match: result)
                }
                // Fall back to matching against relative path
                let filePath = url.standardizedFileURL.path
                let relative = filePath.hasPrefix(rootPath)
                    ? String(filePath.dropFirst(rootPath.count + 1))
                    : filePath
                if let result = FuzzyMatch.match(pattern: searchQuery, candidate: relative) {
                    // Slightly lower score for path matches
                    let adjustedResult = FuzzyMatch.Result(score: result.score - 10, matchedIndices: [])
                    return (url: url, match: adjustedResult)
                }
                return nil
            }
            .sorted { $0.match.score > $1.match.score }

            // Limit results
            if filteredResults.count > 50 {
                filteredResults = Array(filteredResults.prefix(50))
            }
        }

        tableView.reloadData()

        // Select first result
        if !filteredResults.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func searchSymbols(_ query: String) {
        symbolSearchTask?.cancel()
        guard let lsp = lspClient else { return }

        symbolSearchTask = Task { @MainActor in
            do {
                let symbols = try await lsp.workspaceSymbol(query: query)
                guard !Task.isCancelled else { return }
                self.symbolResults = Array(symbols.prefix(50))
                self.tableView.reloadData()
                if !self.symbolResults.isEmpty {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            } catch {
                // Silently fail
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let totalRows = isSymbolMode ? symbolResults.count : filteredResults.count
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let newRow = min(tableView.selectedRow + 1, totalRows - 1)
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
        isSymbolMode ? symbolResults.count : filteredResults.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("OpenQuicklyCell")
        let pathTag = 100

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 14)
            textField.textColor = .white
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            let pathLabel = NSTextField(labelWithString: "")
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            pathLabel.font = NSFont.systemFont(ofSize: 11)
            pathLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            pathLabel.lineBreakMode = .byTruncatingHead
            pathLabel.tag = pathTag
            cell.addSubview(pathLabel)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                pathLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                pathLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                pathLabel.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 1),
            ])
        }

        if isSymbolMode {
            guard row < symbolResults.count else { return nil }
            let sym = symbolResults[row]

            cell.imageView?.image = nil
            cell.textField?.stringValue = "\(sym.kindIcon) \(sym.name)"
            cell.textField?.textColor = NSColor(white: 0.85, alpha: 1.0)

            if let pathLabel = cell.viewWithTag(pathTag) as? NSTextField {
                let rootPath = projectRoot.standardizedFileURL.path
                if let fileURL = URL(string: sym.location.uri) {
                    let filePath = fileURL.path
                    let relative = filePath.hasPrefix(rootPath)
                        ? String(filePath.dropFirst(rootPath.count + 1))
                        : fileURL.lastPathComponent
                    let container = sym.containerName.map { " — \($0)" } ?? ""
                    pathLabel.stringValue = "\(relative):\(sym.location.range.start.line + 1)\(container)"
                } else {
                    pathLabel.stringValue = sym.containerName ?? ""
                }
            }
        } else {
            guard row < filteredResults.count else { return nil }
            let result = filteredResults[row]
            let url = result.url
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)

            let fileName = url.lastPathComponent

            if isRecentMode {
                // Recent mode: plain filename, no highlight
                cell.textField?.stringValue = fileName
                cell.textField?.textColor = NSColor(white: 0.85, alpha: 1.0)
                cell.textField?.font = NSFont.systemFont(ofSize: 14)
            } else {
                // Build attributed string with highlighted match characters
                let attrStr = NSMutableAttributedString(string: fileName, attributes: [
                    .foregroundColor: NSColor(white: 0.85, alpha: 1.0),
                    .font: NSFont.systemFont(ofSize: 14),
                ])
                for idx in result.match.matchedIndices {
                    if idx < fileName.count {
                        attrStr.addAttributes([
                            .foregroundColor: NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0),
                            .font: NSFont.boldSystemFont(ofSize: 14),
                        ], range: NSRange(location: idx, length: 1))
                    }
                }
                cell.textField?.attributedStringValue = attrStr
            }

            // Show relative path
            if let pathLabel = cell.viewWithTag(pathTag) as? NSTextField {
                let rootPath = projectRoot.standardizedFileURL.path
                let filePath = url.deletingLastPathComponent().standardizedFileURL.path
                if filePath.hasPrefix(rootPath) {
                    let relative = String(filePath.dropFirst(rootPath.count))
                    pathLabel.stringValue = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
                } else {
                    pathLabel.stringValue = filePath
                }
            }
        }

        return cell
    }

    // MARK: - Selection

    @objc private func tableDoubleClicked(_ sender: Any?) {
        confirmSelection()
    }

    private func confirmSelection() {
        let row = tableView.selectedRow

        if isSymbolMode {
            guard row >= 0, row < symbolResults.count else { return }
            let sym = symbolResults[row]
            guard let url = URL(string: sym.location.uri) else { return }
            dismiss()
            delegate?.openQuickly(self, didSelectURL: url, atLine: sym.location.range.start.line, column: sym.location.range.start.character)
        } else if row >= 0, row < filteredResults.count {
            let url = filteredResults[row].url
            dismiss()
            if let line = pendingLine {
                delegate?.openQuickly(self, didSelectURL: url, atLine: line, column: 0)
            } else {
                delegate?.openQuickly(self, didSelectURL: url)
            }
        } else if filteredResults.isEmpty, let line = pendingLine {
            // Just ":42" — navigate to line in current file
            dismiss()
            // Handled by delegate as jump-to-line
            delegate?.openQuickly(self, didSelectURL: URL(fileURLWithPath: ""), atLine: line, column: 0)
        }
    }

    deinit {
        indexingTask?.cancel()
        symbolSearchTask?.cancel()
    }
}
