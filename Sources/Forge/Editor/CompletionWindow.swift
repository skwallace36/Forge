import AppKit

/// Floating completion popup that shows LSP completion results near the cursor.
class CompletionWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var allItems: [LSPCompletionItem] = []
    private var items: [LSPCompletionItem] = []
    private var onSelect: ((LSPCompletionItem) -> Void)?

    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 22
    private let windowWidth: CGFloat = 320

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 176),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = NSColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 0.98)

        setupTableView()
    }

    private func setupTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 176))
        contentView.addSubview(scrollView)
        self.contentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func show(items: [LSPCompletionItem], at point: NSPoint, in parentWindow: NSWindow, onSelect: @escaping (LSPCompletionItem) -> Void) {
        guard !items.isEmpty else {
            dismiss()
            return
        }

        self.allItems = items
        self.items = items
        self.onSelect = onSelect
        tableView.reloadData()

        let visibleRows = min(items.count, maxVisibleRows)
        let height = CGFloat(visibleRows) * rowHeight + 4
        let windowPoint = parentWindow.convertPoint(toScreen: point)

        // Position below the cursor, flip above if near bottom of screen
        var origin = NSPoint(x: windowPoint.x, y: windowPoint.y - height)
        if let screen = parentWindow.screen, origin.y < screen.visibleFrame.origin.y {
            origin.y = windowPoint.y + 20
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: windowWidth, height: height), display: true)
        parentWindow.addChildWindow(self, ordered: .above)

        if items.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        allItems = []
        items = []
    }

    /// Filter the completion list by prefix (case-insensitive)
    func filterItems(prefix: String) {
        guard !prefix.isEmpty else {
            items = allItems
            tableView.reloadData()
            resizeToFit()
            return
        }

        let lowered = prefix.lowercased()
        items = allItems.filter { item in
            item.label.lowercased().contains(lowered)
                || (item.insertText?.lowercased().contains(lowered) ?? false)
        }

        if items.isEmpty {
            dismiss()
            return
        }

        tableView.reloadData()
        resizeToFit()

        if items.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func resizeToFit() {
        let visibleRows = min(items.count, maxVisibleRows)
        let height = CGFloat(visibleRows) * rowHeight + 4
        var frame = self.frame
        let oldMaxY = frame.maxY
        frame.size.height = height
        frame.origin.y = oldMaxY - height
        setFrame(frame, display: true)
    }

    var isShowing: Bool {
        parent != nil
    }

    // MARK: - Keyboard Navigation

    func moveSelectionUp() {
        let row = tableView.selectedRow
        if row > 0 {
            tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(row - 1)
        }
    }

    func moveSelectionDown() {
        let row = tableView.selectedRow
        if row < items.count - 1 {
            tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(row + 1)
        }
    }

    func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0 && row < items.count else { return }
        let item = items[row]
        dismiss()
        onSelect?(item)
    }

    @objc private func rowDoubleClicked() {
        confirmSelection()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cellID = NSUserInterfaceItemIdentifier("completionCell")
        let cell: CompletionCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? CompletionCellView {
            cell = reused
        } else {
            cell = CompletionCellView()
            cell.identifier = cellID
        }

        cell.configure(with: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }
}

// MARK: - Completion Cell

private class CompletionCellView: NSTableCellView {

    private let iconLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        iconLabel.alignment = .center
        addSubview(iconLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    func configure(with item: LSPCompletionItem) {
        nameLabel.stringValue = item.label
        detailLabel.stringValue = item.detail ?? ""

        // LSP CompletionItemKind icons
        let (icon, color) = kindDisplay(item.kind)
        iconLabel.stringValue = icon
        iconLabel.textColor = color
    }

    private func kindDisplay(_ kind: Int?) -> (String, NSColor) {
        switch kind {
        case 1: return ("T", NSColor.systemBlue)       // Text
        case 2: return ("M", NSColor.systemPurple)     // Method
        case 3: return ("F", NSColor.systemPurple)     // Function
        case 4: return ("C", NSColor.systemGreen)      // Constructor
        case 5: return ("F", NSColor.systemCyan)       // Field
        case 6: return ("V", NSColor.systemCyan)       // Variable
        case 7: return ("C", NSColor.systemGreen)      // Class
        case 8: return ("I", NSColor.systemGreen)      // Interface
        case 9: return ("M", NSColor.systemYellow)     // Module
        case 10: return ("P", NSColor.systemCyan)      // Property
        case 13: return ("E", NSColor.systemGreen)     // Enum
        case 14: return ("K", NSColor.systemOrange)    // Keyword
        case 22: return ("S", NSColor.systemGreen)     // Struct
        case 23: return ("E", NSColor.systemGreen)     // Event
        case 25: return ("T", NSColor.systemGreen)     // TypeParameter
        default: return ("·", NSColor.systemGray)
        }
    }
}
