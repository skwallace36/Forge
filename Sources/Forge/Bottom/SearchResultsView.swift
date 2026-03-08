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
    func searchResultsView(_ view: SearchResultsView, didSelectResult result: SearchResult, matchLength: Int)
}

/// Displays search results in the bottom panel with clickable file:line entries and replace support.
class SearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SearchResultsViewDelegate?

    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexToggle = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseSensitiveToggle = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
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

        // Replace field
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.placeholderString = "Replace with…"
        replaceField.font = NSFont.systemFont(ofSize: 13)
        replaceField.focusRingType = .none
        replaceField.bezelStyle = .roundedBezel
        replaceField.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)
        replaceField.textColor = NSColor(white: 0.85, alpha: 1.0)
        addSubview(replaceField)

        // Replace button
        replaceButton.translatesAutoresizingMaskIntoConstraints = false
        replaceButton.bezelStyle = .accessoryBarAction
        replaceButton.target = self
        replaceButton.action = #selector(replaceAllClicked)
        addSubview(replaceButton)

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

            replaceField.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 3),
            replaceField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            replaceField.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -6),
            replaceField.heightAnchor.constraint(equalToConstant: 24),

            replaceButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            replaceButton.widthAnchor.constraint(equalToConstant: 80),

            regexToggle.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 3),
            regexToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            caseSensitiveToggle.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 3),
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

    @objc private func replaceAllClicked() {
        let searchText = searchField.stringValue
        let replaceText = replaceField.stringValue
        guard !searchText.isEmpty, !results.isEmpty else { return }

        let isRegex = regexToggle.state == .on
        let isCaseSensitive = caseSensitiveToggle.state == .on

        // Confirm before replacing
        let alert = NSAlert()
        alert.messageText = "Replace All"
        alert.informativeText = "Replace \(results.count) occurrences of \"\(searchText)\" with \"\(replaceText)\"?"
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let count = Self.performReplaceAll(
                searchText: searchText,
                replaceText: replaceText,
                isRegex: isRegex,
                isCaseSensitive: isCaseSensitive,
                results: self?.results ?? [],
            )
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = "Replaced \(count) occurrences"
                // Re-run search to show updated results
                self?.searchFieldChanged(self?.searchField ?? NSSearchField())
            }
        }
    }

    private static func performReplaceAll(
        searchText: String,
        replaceText: String,
        isRegex: Bool,
        isCaseSensitive: Bool,
        results: [SearchResult]
    ) -> Int {
        // Group results by file
        var fileGroups: [URL: [SearchResult]] = [:]
        for result in results {
            fileGroups[result.url, default: []].append(result)
        }

        var totalReplacements = 0
        let searchOptions: String.CompareOptions = isCaseSensitive
            ? (isRegex ? .regularExpression : .literal)
            : (isRegex ? [.regularExpression, .caseInsensitive] : .caseInsensitive)

        for (url, _) in fileGroups {
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var count = 0
            while let range = content.range(of: searchText, options: searchOptions) {
                content.replaceSubrange(range, with: replaceText)
                count += 1
                if count > 10000 { break } // safety limit
            }

            if count > 0 {
                try? content.write(to: url, atomically: true, encoding: .utf8)
                totalReplacements += count
            }
        }

        return totalReplacements
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
            "h", "m", "c", "cpp", "cc", "cxx", "hpp", "mm", "html", "css",
            "xml", "plist", "resolved", "sh", "bash", "zsh", "rb", "go",
            "rs", "toml", "tsx", "jsx", "java", "kt", "kts", "scss",
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

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

                // Find all matches on this line
                var searchStart = lineText.startIndex
                while searchStart < lineText.endIndex {
                    guard let range = lineText.range(of: query, options: searchOptions, range: searchStart..<lineText.endIndex) else {
                        break
                    }
                    let col = lineText.distance(from: lineText.startIndex, to: range.lowerBound) + 1
                    found.append(SearchResult(
                        url: url,
                        line: lineIndex + 1,
                        column: col,
                        lineText: lineText,
                        matchRange: range,
                    ))
                    if found.count >= maxResults { break }
                    searchStart = range.upperBound
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
        let matchLen = results[row].lineText.distance(from: results[row].matchRange.lowerBound, to: results[row].matchRange.upperBound)
        delegate?.searchResultsView(self, didSelectResult: results[row], matchLength: matchLen)
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
        let matchLen = results[row].lineText.distance(from: results[row].matchRange.lowerBound, to: results[row].matchRange.upperBound)
        delegate?.searchResultsView(self, didSelectResult: results[row], matchLength: matchLen)
    }
}
