import AppKit

protocol SourceControlViewDelegate: AnyObject {
    func sourceControlView(_ view: SourceControlView, didSelectFile url: URL)
}

/// Shows git changed files in the bottom panel with status indicators, inline diff, and commit UI.
class SourceControlView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SourceControlViewDelegate?

    private let tableView = NSTableView()
    private let fileListScrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let stageAllButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let commitField = NSTextField()
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let diffView: DiffTextView
    private let diffScrollView: NSScrollView
    private let splitView = NSSplitView()

    private var changedFiles: [(path: String, status: GitStatusTracker.FileStatus, staged: Bool)] = []
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

        // Stage All button
        stageAllButton.translatesAutoresizingMaskIntoConstraints = false
        stageAllButton.bezelStyle = .accessoryBarAction
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllClicked)
        addSubview(stageAllButton)

        // Commit message field
        commitField.translatesAutoresizingMaskIntoConstraints = false
        commitField.placeholderString = "Commit message…"
        commitField.font = NSFont.systemFont(ofSize: 12)
        commitField.focusRingType = .none
        commitField.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)
        commitField.textColor = NSColor(white: 0.85, alpha: 1.0)
        commitField.isBordered = true
        commitField.bezelStyle = .roundedBezel
        addSubview(commitField)

        // Commit button
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        commitButton.bezelStyle = .accessoryBarAction
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        addSubview(commitButton)

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

        // Enable right-click context menu
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

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
            refreshButton.trailingAnchor.constraint(equalTo: stageAllButton.leadingAnchor, constant: -6),

            stageAllButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            stageAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            commitField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            commitField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            commitField.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -6),
            commitField.heightAnchor.constraint(equalToConstant: 24),

            commitButton.centerYAnchor.constraint(equalTo: commitField.centerYAnchor),
            commitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            commitButton.widthAnchor.constraint(equalToConstant: 70),

            splitView.topAnchor.constraint(equalTo: commitField.bottomAnchor, constant: 4),
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
            self?.reloadFiles()
        }
    }

    private func reloadFiles() {
        guard let root = projectRoot else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = Self.fetchChangedFiles(root: root)
            DispatchQueue.main.async {
                self?.changedFiles = files
                self?.tableView.reloadData()
                self?.updateStatusLabel()
            }
        }
    }

    private func updateStatusLabel() {
        if changedFiles.isEmpty {
            statusLabel.stringValue = "No changes"
            diffView.clear()
        } else {
            let staged = changedFiles.filter { $0.staged }.count
            let unstaged = changedFiles.count - staged
            var parts: [String] = []
            if staged > 0 { parts.append("\(staged) staged") }
            if unstaged > 0 { parts.append("\(unstaged) unstaged") }
            statusLabel.stringValue = "\(changedFiles.count) changed — \(parts.joined(separator: ", "))"
        }
    }

    @objc private func refreshClicked() {
        reloadFiles()
    }

    @objc private func stageAllClicked() {
        guard let root = projectRoot else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runGit(["add", "-A"], root: root)
            DispatchQueue.main.async {
                self?.reloadFiles()
            }
        }
    }

    @objc private func commitClicked() {
        let message = commitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            commitField.becomeFirstResponder()
            NSSound.beep()
            return
        }
        guard let root = projectRoot else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = Self.runGit(["commit", "-m", message], root: root)
            DispatchQueue.main.async {
                if success {
                    self?.commitField.stringValue = ""
                    self?.reloadFiles()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    @objc private func tableClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        loadDiff(for: file.path, status: file.status, staged: file.staged, root: root)
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        let url = root.appendingPathComponent(file.path)
        delegate?.sourceControlView(self, didSelectFile: url)
    }

    private func loadDiff(for path: String, status: GitStatusTracker.FileStatus, staged: Bool, root: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff: String
            if status == .untracked {
                let url = root.appendingPathComponent(path)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    diff = content.components(separatedBy: "\n").map { "+\($0)" }.joined(separator: "\n")
                } else {
                    diff = "(Cannot read file)"
                }
            } else if staged {
                diff = Self.fetchDiff(args: ["diff", "--cached", "--", path], root: root)
            } else {
                diff = Self.fetchDiff(args: ["diff", "--", path], root: root)
            }
            DispatchQueue.main.async {
                self?.diffView.showDiff(diff)
            }
        }
    }

    // MARK: - Git Operations

    private func stageFile(at row: Int) {
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runGit(["add", "--", file.path], root: root)
            DispatchQueue.main.async {
                self?.reloadFiles()
            }
        }
    }

    private func unstageFile(at row: Int) {
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runGit(["reset", "HEAD", "--", file.path], root: root)
            DispatchQueue.main.async {
                self?.reloadFiles()
            }
        }
    }

    private func discardChanges(at row: Int) {
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let file = changedFiles[row]

        // Confirm before discarding
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(file.path)?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if file.status == .untracked {
                // Remove untracked file
                let url = root.appendingPathComponent(file.path)
                try? FileManager.default.removeItem(at: url)
            } else {
                Self.runGit(["checkout", "--", file.path], root: root)
            }
            DispatchQueue.main.async {
                self?.reloadFiles()
            }
        }
    }

    @discardableResult
    private static func runGit(_ args: [String], root: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = root
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func fetchDiff(args: [String], root: URL) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = root
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return "(Failed to get diff)" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? "(Binary file or encoding error)"
    }

    private static func fetchChangedFiles(root: URL) -> [(path: String, status: GitStatusTracker.FileStatus, staged: Bool)] {
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

        var result: [(path: String, status: GitStatusTracker.FileStatus, staged: Bool)] = []

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
            } else if x == "A" || y == "A" {
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

            // Staged if the index (x) column shows a change
            let staged = x != " " && x != "?"

            result.append((path: path, status: status, staged: staged))
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

            let stagedIndicator = NSTextField(labelWithString: "")
            stagedIndicator.translatesAutoresizingMaskIntoConstraints = false
            stagedIndicator.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            stagedIndicator.alignment = .center
            stagedIndicator.tag = 201
            cell.addSubview(stagedIndicator)

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingHead
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                stagedIndicator.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stagedIndicator.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                stagedIndicator.widthAnchor.constraint(equalToConstant: 10),
                statusField.leadingAnchor.constraint(equalTo: stagedIndicator.trailingAnchor, constant: 2),
                statusField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                statusField.widthAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: statusField.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = file.path

        // Staged indicator
        if let stagedField = cell.viewWithTag(201) as? NSTextField {
            if file.staged {
                stagedField.stringValue = "\u{25CF}" // filled circle
                stagedField.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
            } else {
                stagedField.stringValue = ""
            }
        }

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

// MARK: - Context Menu

extension SourceControlView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = tableView.clickedRow
        guard row >= 0 && row < changedFiles.count else { return }
        let file = changedFiles[row]

        if file.staged {
            let unstage = NSMenuItem(title: "Unstage", action: #selector(contextUnstage(_:)), keyEquivalent: "")
            unstage.target = self
            unstage.tag = row
            menu.addItem(unstage)
        } else {
            let stage = NSMenuItem(title: "Stage", action: #selector(contextStage(_:)), keyEquivalent: "")
            stage.target = self
            stage.tag = row
            menu.addItem(stage)
        }

        menu.addItem(.separator())

        let discard = NSMenuItem(title: "Discard Changes…", action: #selector(contextDiscard(_:)), keyEquivalent: "")
        discard.target = self
        discard.tag = row
        menu.addItem(discard)

        menu.addItem(.separator())

        let openFile = NSMenuItem(title: "Open File", action: #selector(contextOpenFile(_:)), keyEquivalent: "")
        openFile.target = self
        openFile.tag = row
        menu.addItem(openFile)

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(contextReveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.tag = row
        menu.addItem(reveal)
    }

    @objc private func contextStage(_ sender: NSMenuItem) {
        stageFile(at: sender.tag)
    }

    @objc private func contextUnstage(_ sender: NSMenuItem) {
        unstageFile(at: sender.tag)
    }

    @objc private func contextDiscard(_ sender: NSMenuItem) {
        discardChanges(at: sender.tag)
    }

    @objc private func contextOpenFile(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let url = root.appendingPathComponent(changedFiles[row].path)
        delegate?.sourceControlView(self, didSelectFile: url)
    }

    @objc private func contextReveal(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < changedFiles.count, let root = projectRoot else { return }
        let url = root.appendingPathComponent(changedFiles[row].path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
