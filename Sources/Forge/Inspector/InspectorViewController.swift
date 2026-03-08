import AppKit

/// Right-side inspector panel showing file info and Quick Help.
/// Toggle with ⌘⌥0.
class InspectorViewController: NSViewController {

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // File Info section
    private let fileInfoHeader = InspectorSectionHeader(title: "File Info")
    private let fileNameLabel = InspectorValueRow(label: "Name")
    private let fileTypeLabel = InspectorValueRow(label: "Type")
    private let fileSizeLabel = InspectorValueRow(label: "Size")
    private let lineCountLabel = InspectorValueRow(label: "Lines")
    private let encodingLabel = InspectorValueRow(label: "Encoding")
    private let lineEndingLabel = InspectorValueRow(label: "Line Ending")
    private let tabStyleLabel = InspectorValueRow(label: "Indentation")

    // Quick Help section
    private let quickHelpHeader = InspectorSectionHeader(title: "Quick Help")
    private let quickHelpText = NSTextField(wrappingLabelWithString: "")
    private let noSelectionLabel = NSTextField(labelWithString: "No Selection")

    /// Set by the editor when cursor moves or document changes
    private(set) var currentFileURL: URL?

    /// LSP client for fetching hover info
    weak var lspClient: LSPClient?

    private var hoverWorkItem: DispatchWorkItem?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
        container.addSubview(scrollView)

        // Header divider on the left edge
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        container.addSubview(divider)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2

        let clipView = NSClipView()
        clipView.documentView = contentStack
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        // File info section
        contentStack.addArrangedSubview(fileInfoHeader)
        contentStack.addArrangedSubview(fileNameLabel)
        contentStack.addArrangedSubview(fileTypeLabel)
        contentStack.addArrangedSubview(fileSizeLabel)
        contentStack.addArrangedSubview(lineCountLabel)
        contentStack.addArrangedSubview(encodingLabel)
        contentStack.addArrangedSubview(lineEndingLabel)
        contentStack.addArrangedSubview(tabStyleLabel)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        contentStack.addArrangedSubview(spacer)

        // Quick Help section
        contentStack.addArrangedSubview(quickHelpHeader)

        quickHelpText.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        quickHelpText.textColor = NSColor(white: 0.75, alpha: 1.0)
        quickHelpText.maximumNumberOfLines = 0
        quickHelpText.preferredMaxLayoutWidth = 200
        quickHelpText.translatesAutoresizingMaskIntoConstraints = false
        quickHelpText.isHidden = true
        contentStack.addArrangedSubview(quickHelpText)

        noSelectionLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        noSelectionLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(noSelectionLabel)

        // Set widths to match container
        for row in [fileNameLabel, fileTypeLabel, fileSizeLabel, lineCountLabel,
                    encodingLabel, lineEndingLabel, tabStyleLabel] {
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        fileInfoHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        quickHelpHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        quickHelpText.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -20).isActive = true

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -4),
        ])

        self.view = container
    }

    // MARK: - File Info Update

    func updateFileInfo(document: ForgeDocument?) {
        guard let doc = document else {
            clearFileInfo()
            return
        }

        currentFileURL = doc.url
        fileNameLabel.setValue(doc.fileName)
        fileTypeLabel.setValue(doc.fileExtension.isEmpty ? "Plain Text" : doc.fileExtension.uppercased())

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: doc.url.path),
           let size = attrs[.size] as? UInt64 {
            fileSizeLabel.setValue(formatFileSize(size))
        } else {
            fileSizeLabel.setValue("—")
        }

        // Line count
        let text = doc.textStorage.string
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        lineCountLabel.setValue("\(lineCount)")

        // Encoding
        encodingLabel.setValue("UTF-8")

        // Line ending
        lineEndingLabel.setValue(doc.lineEnding)

        // Tab style
        if let useTabs = doc.detectedUseTabs, useTabs {
            tabStyleLabel.setValue("Tabs")
        } else {
            let width = doc.detectedTabWidth ?? Preferences.shared.tabWidth
            tabStyleLabel.setValue("\(width) Spaces")
        }
    }

    func clearFileInfo() {
        currentFileURL = nil
        fileNameLabel.setValue("—")
        fileTypeLabel.setValue("—")
        fileSizeLabel.setValue("—")
        lineCountLabel.setValue("—")
        encodingLabel.setValue("—")
        lineEndingLabel.setValue("—")
        tabStyleLabel.setValue("—")
        clearQuickHelp()
    }

    // MARK: - Quick Help Update

    func updateQuickHelp(url: URL, line: Int, character: Int) {
        hoverWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let lsp = self.lspClient else { return }
            Task { @MainActor in
                do {
                    guard let hoverText = try await lsp.hover(url: url, line: line, character: character),
                          !hoverText.isEmpty else {
                        self.clearQuickHelp()
                        return
                    }
                    self.quickHelpText.stringValue = hoverText
                    self.quickHelpText.isHidden = false
                    self.noSelectionLabel.isHidden = true
                } catch {
                    self.clearQuickHelp()
                }
            }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func clearQuickHelp() {
        quickHelpText.stringValue = ""
        quickHelpText.isHidden = true
        noSelectionLabel.isHidden = false
    }

    // MARK: - Helpers

    private func formatFileSize(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

// MARK: - Inspector Section Header

private class InspectorSectionHeader: NSView {

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(white: 0.5, alpha: 1.0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        addSubview(separator)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),

            separator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - Inspector Value Row

private class InspectorValueRow: NSView {

    private let valueLabel: NSTextField

    init(label: String) {
        valueLabel = NSTextField(labelWithString: "—")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        valueLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 72),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
    }
}
