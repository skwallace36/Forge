import AppKit

/// Search result from Find in Project.
struct SearchResult {
    let url: URL
    let line: Int       // 1-based
    let column: Int     // 1-based
    let lineText: String
    let matchRange: Range<String.Index>
}

protocol SearchResultsViewDelegate: AnyObject {
    func searchResultsView(_ view: SearchResultsView, didSelectResult result: SearchResult)
}

/// Displays search results in the bottom panel with clickable file:line entries.
class SearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SearchResultsViewDelegate?

    private let searchField = NSSearchField()
    private let regexToggle = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseSensitiveToggle = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var results: [SearchResult] = []
    private var projectRoot: URL?
    private var searchWorkItem: DispatchWorkItem?

    private let bgColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let matchHighlightColor = NSColor(red: 0.85, green: 0.65, blue: 0.20, alpha: 0.4)
    private let filePathColor = NSColor(red: 0.50, green: 0.65, blue: 0.85, alpha: 1.0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find in Project (⌘⇧F)"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        addSubview(searchField)

        // Toggles
        regexToggle.translatesAutoresizingMaskIntoConstraints = false
        regexToggle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        regexToggle.target = self
        regexToggle.action = #selector(toggleChanged(_:))
        addSubview(regexToggle)

        caseSensitiveToggle.translatesAutoresizingMaskIntoConstraints = false
        caseSensitiveToggle.font = NSFont.systemFont(ofSize: 11)
        caseSensitiveToggle.target = self
        caseSensitiveToggle.action = #selector(toggleChanged(_:))
        addSubview(caseSensitiveToggle)

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        addSubview(statusLabel)

        // Table view for results
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(resultDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            regexToggle.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 3),
            regexToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            caseSensitiveToggle.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 3),
            caseSensitiveToggle.leadingAnchor.constraint(equalTo: regexToggle.trailingAnchor, constant: 12),

            statusLabel.centerYAnchor.constraint(equalTo: regexToggle.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: regexToggle.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setProjectRoot(_ url: URL) {
        self.projectRoot = url
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        // Re-run search with new settings
        searchFieldChanged(searchField)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        searchWorkItem?.cancel()

        guard !query.isEmpty, query.count >= 2 else {
            results = []
            tableView.reloadData()
            statusLabel.stringValue = ""
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(query: query)
        }
        searchWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func performSearch(query: String) {
        guard let root = projectRoot else { return }

        let isRegex = regexToggle.state == .on
        let isCaseSensitive = caseSensitiveToggle.state == .on

        var found: [SearchResult] = []
        let fm = FileManager.default
        let maxResults = 1000

        let skipDirs: Set<String> = [
            ".git", ".build", ".swiftpm", "DerivedData", "node_modules",
            "Pods", "__pycache__", "xcuserdata",
        ]
        let searchExtensions: Set<String> = [
            "swift", "json", "md", "yml", "yaml", "txt", "py", "js", "ts",
            "h", "m", "c", "cpp", "html", "css", "xml", "plist", "resolved",
            "sh", "bash", "zsh", "rb", "go", "rs", "toml", "tsx", "jsx",
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Build search options
        let searchOptions: String.CompareOptions = isCaseSensitive
            ? (isRegex ? .regularExpression : .literal)
            : (isRegex ? [.regularExpression, .caseInsensitive] : .caseInsensitive)

        for case let url as URL in enumerator {
            if found.count >= maxResults { break }

            let name = url.lastPathComponent
            if skipDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }

            guard searchExtensions.contains(url.pathExtension.lowercased()) else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: "\n")
            for (lineIndex, lineText) in lines.enumerated() {
                if found.count >= maxResults { break }

                if let range = lineText.range(of: query, options: searchOptions) {
                    let col = lineText.distance(from: lineText.startIndex, to: range.lowerBound) + 1
                    found.append(SearchResult(
                        url: url,
                        line: lineIndex + 1,
                        column: col,
                        lineText: lineText,
                        matchRange: range,
                    ))
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.results = found
            self.tableView.reloadData()
            let suffix = found.count >= maxResults ? " (limit reached)" : ""
            self.statusLabel.stringValue = "\(found.count) results\(suffix)"
        }
    }

    @objc private func resultDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < results.count else { return }
        delegate?.searchResultsView(self, didSelectResult: results[row])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let result = results[row]

        let cellID = NSUserInterfaceItemIdentifier("searchResultCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            let c = NSTableCellView()
            c.identifier = cellID

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])

            cell = c
        }

        // Format: filename:line — matched text with highlight
        let relativePath: String
        if let root = projectRoot {
            relativePath = result.url.path.replacingOccurrences(of: root.path + "/", with: "")
        } else {
            relativePath = result.url.lastPathComponent
        }

        let prefix = "\(relativePath):\(result.line)  "
        let attrStr = NSMutableAttributedString(string: prefix, attributes: [
            .font: font,
            .foregroundColor: filePathColor,
        ])

        // Build the line text with match highlighting
        let trimmedLine = result.lineText.trimmingCharacters(in: .whitespaces)
        let lineAttrStr = NSMutableAttributedString(string: trimmedLine, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: 0.8, alpha: 1.0),
        ])

        // Find the match range within the trimmed text
        let leadingSpaces = result.lineText.prefix(while: { $0 == " " || $0 == "\t" }).count
        let matchStart = result.lineText.distance(from: result.lineText.startIndex, to: result.matchRange.lowerBound) - leadingSpaces
        let matchLength = result.lineText.distance(from: result.matchRange.lowerBound, to: result.matchRange.upperBound)

        if matchStart >= 0 && matchStart + matchLength <= trimmedLine.count {
            let highlightRange = NSRange(location: matchStart, length: matchLength)
            lineAttrStr.addAttribute(.backgroundColor, value: matchHighlightColor, range: highlightRange)
            lineAttrStr.addAttribute(.foregroundColor, value: NSColor.white, range: highlightRange)
        }

        attrStr.append(lineAttrStr)
        cell.textField?.attributedStringValue = attrStr
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        22
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 && row < results.count else { return }
        delegate?.searchResultsView(self, didSelectResult: results[row])
    }
}
