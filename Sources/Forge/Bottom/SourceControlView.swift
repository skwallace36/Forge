import AppKit

protocol SourceControlViewDelegate: AnyObject {
    func sourceControlView(_ view: SourceControlView, didSelectFile url: URL)
}

/// Shows git changed files in the bottom panel with status indicators and inline diff.
class SourceControlView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SourceControlViewDelegate?

    private let tableView = NSTableView()
    private let fileListScrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let diffView: DiffTextView
    private let diffScrollView: NSScrollView
    private let splitView = NSSplitView()

    private var changedFiles: [(path: String, status: GitStatusTracker.FileStatus)] = []
    private var projectRoot: URL?

    private let bgColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: NSRect) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        self.diffScrollView = sv
        self.diffView = DiffTextView.wrap(tv)
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        self.diffScrollView = sv
        self.diffView = DiffTextView.wrap(tv)
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        statusLabel.stringValue = "No changes"
        addSubview(statusLabel)

        // Refresh button
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        addSubview(refreshButton)

        // File list table
        fileListScrollView.translatesAutoresizingMaskIntoConstraints = false
        fileListScrollView.hasVerticalScroller = true
        fileListScrollView.drawsBackground = false
        fileListScrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 24
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.action = #selector(tableClicked)
        tableView.target = self

        fileListScrollView.documentView = tableView

        // Diff view
        diffScrollView.translatesAutoresizingMaskIntoConstraints = false
        diffScrollView.hasVerticalScroller = true
        diffScrollView.autohidesScrollers = true
        diffScrollView.drawsBackground = true
        diffScrollView.backgroundColor = bgColor

        diffView.textView.isEditable = false
        diffView.textView.isSelectable = true
        diffView.textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        diffView.textView.backgroundColor = bgColor
        diffView.textView.textColor = NSColor(white: 0.75, alpha: 1.0)

        // Split view: file list left, diff right
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(fileListScrollView)
        splitView.addSubview(diffScrollView)
        addSubview(splitView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            refreshButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            splitView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // Set initial split position: file list gets ~35% of width
        let totalWidth = splitView.bounds.width
        if totalWidth > 0 {
            splitView.setPosition(min(280, totalWidth * 0.35), ofDividerAt: 0)
        }
    }

    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    func refresh(gitStatus: GitStatusTracker) {
        gitStatus.refresh { [weak self] in
            self?.updateFromTracker(gitStatus)
        }
    }

    private func updateFromTracker(_ tracker: GitStatusTracker) {
        guard let root = projectRoot else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = Self.fetchChangedFiles(root: root)
            DispatchQueue.main.async {
                self?.changedFiles = files
                self?.tableView.reloadData()
                if files.isEmpty {
                    self?.statusLabel.stringValue = "No changes"
                    self?.diffView.clear()
                } else {
                    self?.statusLabel.stringValue = "\(files.count) changed file\(files.count == 1 ? "" : "s")"
                }
            }
        }
    }

    @objc private func refreshClicked() {
        guard let root = projectRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = Self.fetchChangedFiles(root: root)
            DispatchQueue.main.async {
                self?.changedFiles = files
                self?.tableView.reloadData()
                if files.isEmpty {
                    self?.statusLabel.stringValue = "No changes"
                    self?.diffView.clear()
                } else {
                    self?.statusLabel.stringValue = "\(files.count) changed file\(files.count == 1 ? "" : "s")"
                }
            }
        }
    }

    @objc private func tableClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        loadDiff(for: file.path, status: file.status, root: root)
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        let url = root.appendingPathComponent(file.path)
        delegate?.sourceControlView(self, didSelectFile: url)
    }

    private func loadDiff(for path: String, status: GitStatusTracker.FileStatus, root: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff: String
            if status == .untracked {
                // For untracked files, show file contents as all-added
                let url = root.appendingPathComponent(path)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    diff = content.components(separatedBy: "\n").map { "+ \($0)" }.joined(separator: "\n")
                } else {
                    diff = "(Cannot read file)"
                }
            } else {
                diff = Self.fetchDiff(for: path, root: root)
            }
            DispatchQueue.main.async {
                self?.diffView.showDiff(diff)
            }
        }
    }

    private static func fetchDiff(for path: String, root: URL) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["diff", "HEAD", "--", path]
        task.currentDirectoryURL = root
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return "(Failed to get diff)" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? "(Binary file or encoding error)"
    }

    private static func fetchChangedFiles(root: URL) -> [(path: String, status: GitStatusTracker.FileStatus)] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["status", "--porcelain"]
        task.currentDirectoryURL = root
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return [] }

        var result: [(path: String, status: GitStatusTracker.FileStatus)] = []

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 4 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(line.startIndex, offsetBy: 1)]
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var path = String(line[pathStart...])

            // Handle renames
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }

            let status: GitStatusTracker.FileStatus
            if x == "?" || y == "?" {
                status = .untracked
            } else if x == "A" {
                status = .added
            } else if x == "D" || y == "D" {
                status = .deleted
            } else if x == "R" {
                status = .renamed
            } else if x == "U" || y == "U" {
                status = .conflict
            } else {
                status = .modified
            }

            result.append((path: path, status: status))
        }

        return result.sorted { $0.path < $1.path }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        changedFiles.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < changedFiles.count else { return nil }
        let file = changedFiles[row]

        let cellID = NSUserInterfaceItemIdentifier("SCCell")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let statusField = NSTextField(labelWithString: "")
            statusField.translatesAutoresizingMaskIntoConstraints = false
            statusField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            statusField.alignment = .center
            statusField.tag = 200
            cell.addSubview(statusField)

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingHead
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                statusField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                statusField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                statusField.widthAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: statusField.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = file.path

        if let statusField = cell.viewWithTag(200) as? NSTextField {
            switch file.status {
            case .modified:
                statusField.stringValue = "M"
                statusField.textColor = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)
            case .added:
                statusField.stringValue = "A"
                statusField.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
            case .untracked:
                statusField.stringValue = "U"
                statusField.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
            case .deleted:
                statusField.stringValue = "D"
                statusField.textColor = NSColor(red: 0.90, green: 0.40, blue: 0.40, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.90, green: 0.40, blue: 0.40, alpha: 1.0)
            case .renamed:
                statusField.stringValue = "R"
                statusField.textColor = NSColor(red: 0.50, green: 0.70, blue: 0.95, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.50, green: 0.70, blue: 0.95, alpha: 1.0)
            case .conflict:
                statusField.stringValue = "!"
                statusField.textColor = NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0)
                cell.textField?.textColor = NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0)
            }
        }

        return cell
    }
}

// MARK: - Diff Text View

/// Helper that wraps an NSTextView for displaying git diffs with color-coded lines.
class DiffTextView {

    let textView: NSTextView

    private let addedColor = NSColor(red: 0.20, green: 0.35, blue: 0.20, alpha: 1.0)
    private let removedColor = NSColor(red: 0.40, green: 0.18, blue: 0.18, alpha: 1.0)
    private let hunkColor = NSColor(red: 0.30, green: 0.30, blue: 0.50, alpha: 1.0)
    private let metaColor = NSColor(white: 0.45, alpha: 1.0)
    private let addedTextColor = NSColor(red: 0.55, green: 0.90, blue: 0.55, alpha: 1.0)
    private let removedTextColor = NSColor(red: 0.95, green: 0.55, blue: 0.55, alpha: 1.0)
    private let hunkTextColor = NSColor(red: 0.65, green: 0.65, blue: 0.90, alpha: 1.0)
    private let normalTextColor = NSColor(white: 0.75, alpha: 1.0)
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private init(_ textView: NSTextView) {
        self.textView = textView
    }

    static func wrap(_ textView: NSTextView) -> DiffTextView {
        DiffTextView(textView)
    }

    func clear() {
        textView.string = ""
    }

    func showDiff(_ diff: String) {
        guard let ts = textView.textStorage else { return }

        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: "")

        for line in diff.components(separatedBy: "\n") {
            let lineText = line + "\n"
            let attrs: [NSAttributedString.Key: Any]

            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                attrs = [.font: font, .foregroundColor: metaColor]
            } else if line.hasPrefix("@@") {
                attrs = [.font: font, .foregroundColor: hunkTextColor, .backgroundColor: hunkColor]
            } else if line.hasPrefix("+") {
                attrs = [.font: font, .foregroundColor: addedTextColor, .backgroundColor: addedColor]
            } else if line.hasPrefix("-") {
                attrs = [.font: font, .foregroundColor: removedTextColor, .backgroundColor: removedColor]
            } else {
                attrs = [.font: font, .foregroundColor: normalTextColor]
            }

            ts.append(NSAttributedString(string: lineText, attributes: attrs))
        }

        ts.endEditing()
        textView.scrollToBeginningOfDocument(nil)
    }
}
