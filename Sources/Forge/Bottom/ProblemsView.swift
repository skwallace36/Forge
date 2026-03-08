import AppKit

protocol ProblemsViewDelegate: AnyObject {
    func problemsView(_ view: ProblemsView, didSelectProblem url: URL, line: Int, column: Int)
}

/// Aggregates LSP diagnostics into a filterable problems panel.
class ProblemsView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: ProblemsViewDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "No problems")
    private let filterField = NSSearchField()
    private let showErrorsToggle = NSButton(checkboxWithTitle: "Errors", target: nil, action: nil)
    private let showWarningsToggle = NSButton(checkboxWithTitle: "Warnings", target: nil, action: nil)

    private var allProblems: [Problem] = []
    private var filteredProblems: [Problem] = []
    private var projectRoot: URL?

    struct Problem {
        let url: URL
        let line: Int       // 0-based
        let column: Int     // 0-based
        let message: String
        let severity: Severity
        let source: String?

        enum Severity: Int {
            case error = 1
            case warning = 2
            case info = 3
            case hint = 4

            var icon: String {
                switch self {
                case .error: return "\u{2716}" // ✖
                case .warning: return "\u{26A0}" // ⚠
                case .info: return "\u{2139}" // ℹ
                case .hint: return "\u{2022}" // •
                }
            }

            var color: NSColor {
                switch self {
                case .error: return NSColor(red: 0.99, green: 0.35, blue: 0.35, alpha: 1.0)
                case .warning: return NSColor(red: 0.99, green: 0.80, blue: 0.28, alpha: 1.0)
                case .info: return NSColor(red: 0.50, green: 0.70, blue: 0.99, alpha: 1.0)
                case .hint: return NSColor(white: 0.55, alpha: 1.0)
                }
            }
        }
    }

    private let bgColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

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

        // Filter field
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = "Filter problems…"
        filterField.font = NSFont.systemFont(ofSize: 12)
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        addSubview(filterField)

        // Severity toggles
        showErrorsToggle.translatesAutoresizingMaskIntoConstraints = false
        showErrorsToggle.state = .on
        showErrorsToggle.font = NSFont.systemFont(ofSize: 11)
        showErrorsToggle.target = self
        showErrorsToggle.action = #selector(toggleChanged(_:))
        addSubview(showErrorsToggle)

        showWarningsToggle.translatesAutoresizingMaskIntoConstraints = false
        showWarningsToggle.state = .on
        showWarningsToggle.font = NSFont.systemFont(ofSize: 11)
        showWarningsToggle.target = self
        showWarningsToggle.action = #selector(toggleChanged(_:))
        addSubview(showWarningsToggle)

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        addSubview(statusLabel)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProblemColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 28
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(problemDoubleClicked)
        tableView.action = #selector(problemClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterField.widthAnchor.constraint(equalToConstant: 200),
            filterField.heightAnchor.constraint(equalToConstant: 24),

            showErrorsToggle.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            showErrorsToggle.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 12),

            showWarningsToggle.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            showWarningsToggle.leadingAnchor.constraint(equalTo: showErrorsToggle.trailingAnchor, constant: 8),

            statusLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    /// Update diagnostics from LSP for a specific file.
    func updateDiagnostics(url: URL, diagnostics: [LSPDiagnostic]) {
        // Remove existing problems for this file
        allProblems.removeAll { $0.url == url }

        // Add new problems
        for d in diagnostics {
            let severity = Problem.Severity(rawValue: d.severity ?? 3) ?? .info
            allProblems.append(Problem(
                url: url,
                line: d.range.start.line,
                column: d.range.start.character,
                message: d.message,
                severity: severity,
                source: d.source,
            ))
        }

        // Sort: errors first, then warnings, then by file
        allProblems.sort { a, b in
            if a.severity.rawValue != b.severity.rawValue {
                return a.severity.rawValue < b.severity.rawValue
            }
            if a.url.path != b.url.path {
                return a.url.path < b.url.path
            }
            return a.line < b.line
        }

        applyFilter()
    }

    private func applyFilter() {
        let showErrors = showErrorsToggle.state == .on
        let showWarnings = showWarningsToggle.state == .on
        let filterText = filterField.stringValue.lowercased()

        filteredProblems = allProblems.filter { problem in
            // Severity filter
            switch problem.severity {
            case .error:
                if !showErrors { return false }
            case .warning:
                if !showWarnings { return false }
            default:
                break
            }

            // Text filter
            if !filterText.isEmpty {
                let text = "\(problem.url.lastPathComponent) \(problem.message)".lowercased()
                if !text.contains(filterText) { return false }
            }

            return true
        }

        tableView.reloadData()

        let errors = allProblems.filter { $0.severity == .error }.count
        let warnings = allProblems.filter { $0.severity == .warning }.count
        if allProblems.isEmpty {
            statusLabel.stringValue = "No problems"
        } else {
            var parts: [String] = []
            if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
            if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
            statusLabel.stringValue = parts.joined(separator: ", ")
        }
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        applyFilter()
    }

    @objc private func problemClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredProblems.count else { return }
        let problem = filteredProblems[row]
        delegate?.problemsView(self, didSelectProblem: problem.url, line: problem.line, column: problem.column)
    }

    @objc private func problemDoubleClicked() {
        problemClicked()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredProblems.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredProblems.count else { return nil }
        let problem = filteredProblems[row]

        let cellID = NSUserInterfaceItemIdentifier("ProblemCell")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let severityLabel = NSTextField(labelWithString: "")
            severityLabel.translatesAutoresizingMaskIntoConstraints = false
            severityLabel.font = NSFont.systemFont(ofSize: 12)
            severityLabel.alignment = .center
            severityLabel.tag = 300
            cell.addSubview(severityLabel)

            let messageLabel = NSTextField(labelWithString: "")
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            messageLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
            messageLabel.lineBreakMode = .byTruncatingTail
            cell.addSubview(messageLabel)
            cell.textField = messageLabel

            let fileLabel = NSTextField(labelWithString: "")
            fileLabel.translatesAutoresizingMaskIntoConstraints = false
            fileLabel.font = NSFont.systemFont(ofSize: 11)
            fileLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            fileLabel.lineBreakMode = .byTruncatingHead
            fileLabel.tag = 301
            cell.addSubview(fileLabel)

            NSLayoutConstraint.activate([
                severityLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                severityLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                severityLabel.widthAnchor.constraint(equalToConstant: 18),

                messageLabel.leadingAnchor.constraint(equalTo: severityLabel.trailingAnchor, constant: 4),
                messageLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                messageLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),

                fileLabel.leadingAnchor.constraint(equalTo: severityLabel.trailingAnchor, constant: 4),
                fileLabel.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
                fileLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            ])
        }

        // Severity icon
        if let sevLabel = cell.viewWithTag(300) as? NSTextField {
            sevLabel.stringValue = problem.severity.icon
            sevLabel.textColor = problem.severity.color
        }

        // Message
        cell.textField?.stringValue = problem.message

        // File location
        if let fileLabel = cell.viewWithTag(301) as? NSTextField {
            let relativePath: String
            if let root = projectRoot {
                relativePath = problem.url.path.replacingOccurrences(of: root.path + "/", with: "")
            } else {
                relativePath = problem.url.lastPathComponent
            }
            fileLabel.stringValue = "\(relativePath):\(problem.line + 1):\(problem.column + 1)"
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        28
    }
}
