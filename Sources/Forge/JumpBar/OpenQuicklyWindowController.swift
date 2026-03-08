import AppKit

protocol OpenQuicklyDelegate: AnyObject {
    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL)
}

/// Modal overlay for ⇧⌘O — fuzzy file search.
class OpenQuicklyWindowController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: OpenQuicklyDelegate?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allFiles: [URL] = []
    private var filteredResults: [(url: URL, match: FuzzyMatch.Result)] = []
    private var indexingTask: Task<Void, Never>?

    private let projectRoot: URL

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
        searchField.placeholderString = "Open Quickly — type a filename"
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
            var files: [URL] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }

            let skipDirs: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "node_modules", "Pods"]

            for case let url as URL in enumerator {
                if Task.isCancelled { return }

                let name = url.lastPathComponent
                if skipDirs.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }

                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir && skipDirs.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }

                if !isDir {
                    files.append(url)
                }
            }

            await MainActor.run {
                self?.allFiles = files
            }
        }
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
        filteredResults = []
        tableView.reloadData()
    }

    func dismiss() {
        window?.parent?.removeChildWindow(window!)
        window?.orderOut(nil)
    }

    // MARK: - Search

    private func updateSearch() {
        let query = searchField.stringValue

        if query.isEmpty {
            filteredResults = []
        } else {
            let rootPath = projectRoot.standardizedFileURL.path
            filteredResults = allFiles.compactMap { url in
                // Try matching against filename first (higher priority)
                let fileName = url.lastPathComponent
                if let result = FuzzyMatch.match(pattern: query, candidate: fileName) {
                    return (url: url, match: result)
                }
                // Fall back to matching against relative path
                let filePath = url.standardizedFileURL.path
                let relative = filePath.hasPrefix(rootPath)
                    ? String(filePath.dropFirst(rootPath.count + 1))
                    : filePath
                if let result = FuzzyMatch.match(pattern: query, candidate: relative) {
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

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let newRow = min(tableView.selectedRow + 1, filteredResults.count - 1)
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
        filteredResults.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredResults.count else { return nil }

        let result = filteredResults[row]
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

        let url = result.url
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)

        // Build attributed string with highlighted match characters
        let fileName = url.lastPathComponent
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

        return cell
    }

    // MARK: - Selection

    @objc private func tableDoubleClicked(_ sender: Any?) {
        confirmSelection()
    }

    private func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredResults.count else { return }

        let url = filteredResults[row].url
        dismiss()
        delegate?.openQuickly(self, didSelectURL: url)
    }

    deinit {
        indexingTask?.cancel()
    }
}
