import AppKit

/// Container for the jump bar + tab bar + editor view + status bar. Lives in the center pane.
class EditorContainerViewController: NSViewController, TabBarDelegate {

    let project: ForgeProject
    private let jumpBar = JumpBar()
    private let tabBar = TabBar()
    private let editor = ForgeEditorManager()
    private let minimap = MinimapView()
    private let statusBar = StatusBar()
    private let placeholderLabel = NSTextField(labelWithString: "Open a file to start editing\n\n⇧⌘O  Open Quickly\n⌘O    Open File\n⌘N    New File")
    private let binaryLabel = NSTextField(labelWithString: "")

    init(project: ForgeProject) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = DropTargetView()
        container.onFileDrop = { [weak self] urls in
            for url in urls {
                self?.windowController?.openFile(url)
            }
        }

        // Jump bar (breadcrumb path)
        jumpBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(jumpBar)

        // Tab bar
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        container.addSubview(tabBar)

        // Status bar at bottom
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        // Gutter sits to the LEFT of the scroll view (not overlaying —
        // overlaying breaks NSTextView rendering in layer-backed hierarchies)
        editor.gutterView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor.gutterView)

        // Editor scroll view
        let sv = editor.scrollView
        sv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sv)

        // Minimap
        minimap.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(minimap)

        // Placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .light)
        placeholderLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        container.addSubview(placeholderLabel)

        // Binary file placeholder
        binaryLabel.translatesAutoresizingMaskIntoConstraints = false
        binaryLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        binaryLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        binaryLabel.alignment = .center
        binaryLabel.isHidden = true
        container.addSubview(binaryLabel)

        NSLayoutConstraint.activate([
            jumpBar.topAnchor.constraint(equalTo: container.topAnchor),
            jumpBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            jumpBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            jumpBar.heightAnchor.constraint(equalToConstant: 24),

            tabBar.topAnchor.constraint(equalTo: jumpBar.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: statusBar.barHeight),

            // Gutter: left side, between tab bar and status bar
            editor.gutterView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editor.gutterView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.gutterView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            editor.gutterView.widthAnchor.constraint(equalToConstant: editor.gutterWidth),

            // Scroll view: to the right of gutter, left of minimap
            sv.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: editor.gutterView.trailingAnchor),
            sv.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            sv.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Minimap: right side
            minimap.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimap.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            minimap.widthAnchor.constraint(equalToConstant: 80),

            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            binaryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            binaryLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }

    /// Set this to enable jump-to-definition navigation
    weak var windowController: MainWindowController?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire up LSP diagnostics
        editor.lspClient = project.lspClient
        project.lspClient.onDiagnostics = { [weak self] url, diagnostics in
            guard let self = self,
                  let currentDoc = self.project.tabManager.currentDocument,
                  currentDoc.url == url else { return }
            self.editor.updateDiagnostics(diagnostics)
        }

        // Wire up cursor position to status bar
        editor.onCursorChange = { [weak self] line, column, totalLines, selectionLength in
            guard let self = self else { return }
            let ext = self.project.tabManager.currentDocument?.fileExtension
            self.statusBar.update(line: line, column: column, totalLines: totalLines, fileExtension: ext, selectionLength: selectionLength)
        }

        // Wire up jump-to-definition
        editor.onJumpToDefinition = { [weak self] url, line, column in
            self?.windowController?.openFile(url, atLine: line, column: column)
        }

        // Wire up jump bar symbol navigation
        jumpBar.onSymbolSelected = { [weak self] line, column in
            self?.editor.scrollToLine(line, column: column)
        }

        jumpBar.onRequestSymbols = { [weak self] completion in
            guard let self = self,
                  let doc = self.project.tabManager.currentDocument else {
                completion([])
                return
            }
            Task {
                let symbols = (try? await self.project.lspClient.documentSymbols(url: doc.url)) ?? []
                await MainActor.run {
                    completion(symbols)
                }
            }
        }

        refreshEditor()

        // Initial git branch display
        statusBar.updateBranch(project.gitStatus.currentBranch)
        project.gitStatus.refresh { [weak self] in
            self?.statusBar.updateBranch(self?.project.gitStatus.currentBranch)
        }
    }

    func refreshEditor() {
        let tabManager = project.tabManager
        tabBar.update(tabs: tabManager.tabs, selectedIndex: tabManager.selectedIndex)

        if let doc = tabManager.currentDocument {
            if doc.isBinary {
                editor.scrollView.isHidden = true
                editor.gutterView.isHidden = true
                minimap.isHidden = true
                placeholderLabel.isHidden = true
                binaryLabel.stringValue = "\(doc.fileName) is a binary file and cannot be displayed."
                binaryLabel.isHidden = false
            } else {
                editor.scrollView.isHidden = false
                editor.gutterView.isHidden = false
                minimap.isHidden = !Preferences.shared.showMinimap
                placeholderLabel.isHidden = true
                binaryLabel.isHidden = true
                minimap.textView = editor.textView
                minimap.scrollView = editor.scrollView
                editor.minimapView = minimap
            }
            editor.displayDocument(doc)
            jumpBar.update(fileURL: doc.url, projectRoot: project.rootURL)
            statusBar.update(line: 1, column: 1, totalLines: 1, fileExtension: doc.fileExtension)
            statusBar.updateLineEnding(doc.textStorage.string)

            // Fetch git diff change markers for gutter
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let changes = self.project.gitStatus.changedLines(for: doc.url)
                DispatchQueue.main.async {
                    self.editor.gutterView.changedLines = changes
                    self.editor.gutterView.needsDisplay = true
                }
            }

            // Update window title with modified state
            if let window = view.window {
                let modified = doc.isModified ? " — Edited" : ""
                window.title = "\(doc.fileName)\(modified)"
            }
        } else {
            editor.scrollView.isHidden = true
            editor.gutterView.isHidden = true
            minimap.isHidden = true
            placeholderLabel.isHidden = false
            binaryLabel.isHidden = true
            jumpBar.update(fileURL: nil, projectRoot: nil)
        }
    }

    // MARK: - TabBarDelegate

    func tabBar(_ tabBar: TabBar, didSelectTabAt index: Int) {
        project.tabManager.select(at: index)
        refreshEditor()
    }

    func tabBar(_ tabBar: TabBar, didMoveTabFrom sourceIndex: Int, to destIndex: Int) {
        project.tabManager.moveTab(from: sourceIndex, to: destIndex)
    }

    func tabBar(_ tabBar: TabBar, didCloseTabAt index: Int) {
        guard index >= 0 && index < project.tabManager.tabs.count else { return }
        let doc = project.tabManager.tabs[index].document

        if doc.isModified {
            // Sync before checking
            if index == project.tabManager.selectedIndex {
                editor.syncDocumentContent()
            }

            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \(doc.fileName)?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn: // Save
                try? doc.save()
            case .alertSecondButtonReturn: // Don't Save
                break
            default: // Cancel
                return
            }
        }

        project.tabManager.close(at: index)
        refreshEditor()
    }

    func tabBarDidRequestCloseOthers(_ tabBar: TabBar, keepingIndex index: Int) {
        project.tabManager.closeOthers(keepingIndex: index)
        refreshEditor()
    }

    func tabBarDidRequestCloseAll(_ tabBar: TabBar) {
        project.tabManager.closeAll()
        refreshEditor()
    }

    func tabBarDidRequestCloseToRight(_ tabBar: TabBar, fromIndex index: Int) {
        project.tabManager.closeToRight(fromIndex: index)
        refreshEditor()
    }

    // MARK: - Minimap Toggle

    @objc func toggleMinimap(_ sender: Any?) {
        let prefs = Preferences.shared
        prefs.showMinimap = !prefs.showMinimap
        minimap.isHidden = !prefs.showMinimap
    }

    // MARK: - Word Wrap Toggle

    @objc func toggleWordWrap(_ sender: Any?) {
        let prefs = Preferences.shared
        prefs.wordWrap = !prefs.wordWrap
    }

    // MARK: - Toggle Comment (forwarded to editor manager)

    @objc func toggleComment(_ sender: Any?) {
        editor.toggleComment(sender)
    }

    @objc func reindentSelection(_ sender: Any?) {
        editor.reindentSelection(sender)
    }

    @objc func renameSymbol(_ sender: Any?) {
        editor.renameSymbol(sender)
    }

    @objc func increaseFontSize(_ sender: Any?) {
        editor.increaseFontSize()
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        editor.decreaseFontSize()
    }

    @objc func resetFontSize(_ sender: Any?) {
        editor.resetFontSize()
    }

    @objc func sortLines(_ sender: Any?) {
        editor.sortLines()
    }

    @objc func removeDuplicateLines(_ sender: Any?) {
        editor.removeDuplicateLines()
    }

    @objc func goToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number:"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Line number"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let lineNumber = Int(textField.stringValue.trimmingCharacters(in: .whitespaces)),
              lineNumber > 0 else { return }
        editor.scrollToLine(lineNumber - 1, column: 0) // convert to 0-based
    }

    // MARK: - Navigation

    func scrollToLine(_ line: Int, column: Int) {
        editor.scrollToLine(line, column: column)
    }

    // MARK: - Focus

    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    // MARK: - Save support

    func syncDocumentContent() {
        editor.syncDocumentContent()
    }
}

// MARK: - Drop Target View

/// NSView subclass that accepts file drops from Finder
private class DropTargetView: NSView {

    var onFileDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else {
            return false
        }

        let fileURLs = urls.filter { !$0.hasDirectoryPath }
        guard !fileURLs.isEmpty else { return false }

        onFileDrop?(fileURLs)
        return true
    }
}
