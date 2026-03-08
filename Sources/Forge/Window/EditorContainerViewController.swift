import AppKit

/// Container for the jump bar + tab bar + editor view + status bar. Lives in the center pane.
class EditorContainerViewController: NSViewController, TabBarDelegate {

    let project: ForgeProject
    private let jumpBar = JumpBar()
    private let tabBar = TabBar()
    private let editor = ForgeEditorManager()
    private let minimap = MinimapView()
    private let stickyScroll = StickyScrollView()
    private let statusBar = StatusBar()
    private let findReplaceBar = FindReplaceBar()
    private lazy var findBarHeightConstraint = findReplaceBar.heightAnchor.constraint(equalToConstant: 0)
    private lazy var findBarTopConstraint = findReplaceBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
    private let placeholderLabel = NSTextField(labelWithString: "Open a file to start editing\n\n⇧⌘O  Open Quickly\n⌘O    Open File\n⌘N    New File")
    private let binaryLabel = NSTextField(labelWithString: "")
    private let imagePreview = NSImageView()
    private lazy var gutterWidthConstraint = editor.gutterView.widthAnchor.constraint(equalToConstant: editor.gutterWidth)
    private var symbolRefreshWorkItem: DispatchWorkItem?
    private var lastScopeLine: Int = -1

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
        tabBar.projectRootURL = project.rootURL
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

        // Find/Replace bar (hidden until ⌘F)
        findReplaceBar.translatesAutoresizingMaskIntoConstraints = false
        findReplaceBar.isHidden = true
        container.addSubview(findReplaceBar)

        // Sticky scroll (overlays top of editor, hidden when not needed)
        stickyScroll.translatesAutoresizingMaskIntoConstraints = false
        stickyScroll.isHidden = true
        container.addSubview(stickyScroll)

        // Welcome placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        updateWelcomeText()
        container.addSubview(placeholderLabel)

        // Binary file placeholder
        binaryLabel.translatesAutoresizingMaskIntoConstraints = false
        binaryLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        binaryLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        binaryLabel.alignment = .center
        binaryLabel.maximumNumberOfLines = 3
        binaryLabel.isHidden = true
        container.addSubview(binaryLabel)

        // Image preview for binary image files
        imagePreview.translatesAutoresizingMaskIntoConstraints = false
        imagePreview.imageScaling = .scaleProportionallyDown
        imagePreview.imageAlignment = .alignCenter
        imagePreview.isHidden = true
        container.addSubview(imagePreview)

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

            // Find/Replace bar
            findBarTopConstraint,
            findReplaceBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findReplaceBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeightConstraint,

            // Gutter: left side, between find bar and status bar
            editor.gutterView.topAnchor.constraint(equalTo: findReplaceBar.bottomAnchor),
            editor.gutterView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.gutterView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            gutterWidthConstraint,

            // Scroll view: to the right of gutter, left of minimap
            sv.topAnchor.constraint(equalTo: findReplaceBar.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: editor.gutterView.trailingAnchor),
            sv.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            sv.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Minimap: right side
            minimap.topAnchor.constraint(equalTo: findReplaceBar.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimap.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            minimap.widthAnchor.constraint(equalToConstant: 80),

            // Sticky scroll: overlays top of editor scroll view
            stickyScroll.topAnchor.constraint(equalTo: findReplaceBar.bottomAnchor),
            stickyScroll.leadingAnchor.constraint(equalTo: editor.gutterView.trailingAnchor),
            stickyScroll.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            binaryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            binaryLabel.bottomAnchor.constraint(equalTo: container.centerYAnchor, constant: 160),

            imagePreview.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imagePreview.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            imagePreview.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
            imagePreview.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -160),
        ])

        self.view = container
    }

    /// Set this to enable jump-to-definition navigation
    weak var windowController: MainWindowController?

    /// Callback to send code to Claude panel: (code, fileName, line)
    var onSendToClaude: ((String, String?, Int?) -> Void)?

    /// Callback when cursor changes: (url, line, column) — for inspector Quick Help
    var onCursorPositionChange: ((URL, Int, Int) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire up LSP (diagnostics routing is handled by MainSplitViewController)
        editor.lspClient = project.lspClient
        editor.projectRootURL = project.rootURL

        // Update gutter width when line count changes
        editor.onGutterWidthChange = { [weak self] newWidth in
            self?.gutterWidthConstraint.constant = newWidth
        }

        // Wire up cursor position to status bar, inspector, and scope display
        editor.onCursorChange = { [weak self] line, column, totalLines, selectionLength in
            guard let self = self else { return }
            let doc = self.project.tabManager.currentDocument
            self.statusBar.update(
                line: line, column: column, totalLines: totalLines,
                fileExtension: doc?.fileExtension, selectionLength: selectionLength,
                detectedTabWidth: doc?.detectedTabWidth, detectedUseTabs: doc?.detectedUseTabs
            )
            // Forward cursor position for Quick Help in inspector
            if let url = doc?.url {
                self.onCursorPositionChange?(url, line - 1, column - 1)
            }
            // Update scope display in jump bar (debounced — only when line changes)
            if line != self.lastScopeLine {
                self.lastScopeLine = line
                self.jumpBar.updateScope(line: line - 1, column: column - 1)
            }
        }

        // Wire up jump-to-definition
        editor.onJumpToDefinition = { [weak self] url, line, column in
            self?.windowController?.openFile(url, atLine: line, column: column)
        }

        // Wire up multi-file edits (from LSP rename)
        editor.onApplyEdits = { [weak self] url, edits in
            guard let self = self else { return }
            let doc = self.project.document(for: url)
            self.applyTextEdits(edits, to: doc)
        }

        // Wire up send to Claude
        editor.onSendToClaude = { [weak self] code, fileName, line in
            self?.onSendToClaude?(code, fileName, line)
        }

        // Wire up Find All References
        editor.onShowReferences = { [weak self] locations in
            self?.showReferencesMenu(locations)
        }

        // Promote preview tab to permanent when user edits the file
        editor.onTextDidChange = { [weak self] in
            guard let self = self else { return }
            self.project.tabManager.promoteCurrentPreview()
            // Refresh tab bar to update italic → regular font and modified dot
            let tm = self.project.tabManager
            self.tabBar.update(tabs: tm.tabs, selectedIndex: tm.selectedIndex, tabManager: tm)
            // Update window close-button edited indicator
            self.view.window?.isDocumentEdited = self.project.tabManager.currentDocument?.isModified ?? false
            // Refresh document symbols for scope display (debounced)
            if let url = self.project.tabManager.currentDocument?.url {
                self.refreshDocumentSymbols(for: url)
            }
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

        jumpBar.documentTextProvider = { [weak self] in
            self?.editor.textView.string
        }

        jumpBar.onFileSelected = { [weak self] url in
            self?.windowController?.openFile(url)
        }

        // Wire up sticky scroll
        editor.onScroll = { [weak self] in
            guard let self = self, Preferences.shared.stickyScroll else {
                self?.stickyScroll.isHidden = true
                return
            }
            self.stickyScroll.updateStickyLines()
        }
        stickyScroll.onLineClicked = { [weak self] charOffset in
            guard let self = self else { return }
            self.editor.textView.setSelectedRange(NSRange(location: charOffset, length: 0))
            self.editor.textView.scrollRangeToVisible(NSRange(location: charOffset, length: 0))
        }

        // Wire up find bar
        editor.onShowFindBar = { [weak self] withReplace, initialText in
            self?.showFindBar(withReplace: withReplace, initialText: initialText)
        }

        findReplaceBar.onSearch = { [weak self] query, options -> [NSRange] in
            guard let self = self else { return [] }
            return self.editor.findAll(query: query, options: options)
        }

        findReplaceBar.onNavigate = { [weak self] direction in
            self?.editor.navigateFind(direction: direction)
        }

        findReplaceBar.onReplace = { [weak self] replacement in
            self?.editor.replaceCurrent(with: replacement)
        }

        findReplaceBar.onReplaceAll = { [weak self] replacement in
            self?.editor.replaceAll(with: replacement)
        }

        editor.onFindBarRefresh = { [weak self] in
            self?.findReplaceBar.refreshSearch()
        }

        findReplaceBar.onHeightChange = { [weak self] height in
            self?.findBarHeightConstraint.constant = height
            self?.view.needsLayout = true
        }

        findReplaceBar.onDismiss = { [weak self] in
            guard let self = self else { return }
            self.editor.clearFindHighlights()
            self.findBarHeightConstraint.constant = 0
            self.findReplaceBar.isHidden = true
            self.view.window?.makeFirstResponder(self.editor.textView)
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
        tabBar.update(tabs: tabManager.tabs, selectedIndex: tabManager.selectedIndex, tabManager: tabManager)

        if let doc = tabManager.currentDocument {
            if doc.isBinary {
                editor.scrollView.isHidden = true
                editor.gutterView.isHidden = true
                minimap.isHidden = true
                placeholderLabel.isHidden = true
                imagePreview.isHidden = true

                // Check if it's an image file
                let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "ico", "webp", "heic", "svg"]
                if imageExts.contains(doc.fileExtension.lowercased()),
                   let image = NSImage(contentsOf: doc.url) {
                    imagePreview.image = image
                    imagePreview.isHidden = false
                    let sizeStr = "\(Int(image.size.width)) x \(Int(image.size.height))"
                    binaryLabel.stringValue = "\(doc.fileName) (\(sizeStr))"
                } else {
                    let sizeStr = formatFileSize(doc.url)
                    binaryLabel.stringValue = "\(doc.fileName)\nBinary file \(sizeStr)"
                }
                binaryLabel.isHidden = false
            } else {
                editor.scrollView.isHidden = false
                editor.gutterView.isHidden = false
                minimap.isHidden = !Preferences.shared.showMinimap
                placeholderLabel.isHidden = true
                binaryLabel.isHidden = true
                imagePreview.isHidden = true
                minimap.textView = editor.textView
                minimap.scrollView = editor.scrollView
                editor.minimapView = minimap
                stickyScroll.textView = editor.textView
                stickyScroll.scrollView = editor.scrollView
            }
            editor.displayDocument(doc)
            jumpBar.update(fileURL: doc.url, projectRoot: project.rootURL)
            statusBar.update(line: 1, column: 1, totalLines: 1, fileExtension: doc.fileExtension)
            statusBar.setLineEnding(doc.lineEnding)

            // Fetch document symbols for scope display
            refreshDocumentSymbols(for: doc.url)

            // Fetch git diff change markers and blame for gutter
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let changes = self.project.gitStatus.changedLines(for: doc.url)
                let blame = self.project.gitStatus.blame(for: doc.url)
                DispatchQueue.main.async {
                    self.editor.gutterView.changedLines = changes
                    self.editor.gutterView.blameInfo = blame
                    self.editor.gutterView.needsDisplay = true
                }
            }

            // Update window title, proxy icon, and native edited indicator
            if let window = view.window {
                window.title = doc.fileName
                let rootPath = project.rootURL.standardizedFileURL.path
                let filePath = doc.url.standardizedFileURL.path
                if filePath.hasPrefix(rootPath) {
                    let relative = String(filePath.dropFirst(rootPath.count + 1))
                    window.subtitle = relative
                } else {
                    window.subtitle = (doc.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                }
                window.representedURL = doc.url
                window.isDocumentEdited = doc.isModified
            }
        } else {
            editor.scrollView.isHidden = true
            editor.gutterView.isHidden = true
            minimap.isHidden = true
            placeholderLabel.isHidden = false
            binaryLabel.isHidden = true
            imagePreview.isHidden = true
            jumpBar.update(fileURL: nil, projectRoot: nil)

            if let window = view.window {
                window.title = project.displayName
                window.subtitle = (project.rootURL.path as NSString).abbreviatingWithTildeInPath
                window.representedURL = nil
                window.isDocumentEdited = false
            }
        }
    }

    // MARK: - Welcome Screen

    private func updateWelcomeText() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 6

        let str = NSMutableAttributedString()

        // App name
        str.append(NSAttributedString(string: "Forge\n", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .ultraLight),
            .foregroundColor: NSColor(white: 0.50, alpha: 1.0),
            .paragraphStyle: para,
        ]))

        // Project name
        str.append(NSAttributedString(string: "\(project.displayName)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(white: 0.40, alpha: 1.0),
            .paragraphStyle: para,
        ]))

        // Quick actions
        let shortcutPara = NSMutableParagraphStyle()
        shortcutPara.alignment = .center
        shortcutPara.lineSpacing = 4

        let dimColor = NSColor(white: 0.30, alpha: 1.0)
        let keyColor = NSColor(white: 0.45, alpha: 1.0)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let shortcuts: [(String, String)] = [
            ("⇧⌘O", "Open Quickly"),
            ("⌘O", "Open File"),
            ("⌘N", "New File"),
            ("⇧⌘P", "Command Palette"),
            ("⌘⇧F", "Find in Project"),
        ]

        for (key, label) in shortcuts {
            str.append(NSAttributedString(string: "\(key)  ", attributes: [
                .font: monoFont,
                .foregroundColor: keyColor,
                .paragraphStyle: shortcutPara,
            ]))
            str.append(NSAttributedString(string: "\(label)\n", attributes: [
                .font: labelFont,
                .foregroundColor: dimColor,
                .paragraphStyle: shortcutPara,
            ]))
        }

        placeholderLabel.attributedStringValue = str
    }

    // MARK: - Document Symbols

    private func refreshDocumentSymbols(for url: URL) {
        symbolRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task {
                let symbols = (try? await self.project.lspClient.documentSymbols(url: url)) ?? []
                await MainActor.run {
                    self.jumpBar.updateSymbols(symbols)
                    // Re-evaluate scope at current cursor position
                    if self.lastScopeLine > 0 {
                        self.jumpBar.updateScope(line: self.lastScopeLine - 1, column: 0)
                    }
                }
            }
        }
        symbolRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    // MARK: - TabBarDelegate

    func tabBar(_ tabBar: TabBar, didSelectTabAt index: Int) {
        // Sync current document before switching tabs
        editor.syncDocumentContent()
        project.tabManager.select(at: index)
        refreshEditor()
    }

    func tabBar(_ tabBar: TabBar, didMoveTabFrom sourceIndex: Int, to destIndex: Int) {
        project.tabManager.moveTab(from: sourceIndex, to: destIndex)
    }

    func tabBar(_ tabBar: TabBar, didTogglePinAt index: Int) {
        project.tabManager.togglePin(at: index)
        refreshEditor()
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
        // Check for unsaved changes in tabs being closed
        editor.syncDocumentContent()
        for (i, tab) in project.tabManager.tabs.enumerated() where i != index {
            if tab.isModified && !promptSaveForClose(doc: tab.document) { return }
        }
        project.tabManager.closeOthers(keepingIndex: index)
        refreshEditor()
    }

    func tabBarDidRequestCloseAll(_ tabBar: TabBar) {
        editor.syncDocumentContent()
        for tab in project.tabManager.tabs {
            if tab.isModified && !promptSaveForClose(doc: tab.document) { return }
        }
        project.tabManager.closeAll()
        refreshEditor()
    }

    func tabBarDidRequestCloseToRight(_ tabBar: TabBar, fromIndex index: Int) {
        editor.syncDocumentContent()
        let tabs = project.tabManager.tabs
        for i in (index + 1)..<tabs.count {
            if tabs[i].isModified && !promptSaveForClose(doc: tabs[i].document) { return }
        }
        project.tabManager.closeToRight(fromIndex: index)
        refreshEditor()
    }

    func tabBarDidRequestNewFile(_ tabBar: TabBar) {
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Enter the file name:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "filename.swift"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let fileURL = project.rootURL.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            let alert = NSAlert()
            alert.messageText = "Could not create file"
            alert.informativeText = "Failed to create \"\(name)\" in the project root."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        windowController?.openFile(fileURL)
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

    // MARK: - Invisible Characters Toggle

    @objc func toggleInvisibles(_ sender: Any?) {
        let prefs = Preferences.shared
        prefs.showInvisibles = !prefs.showInvisibles
        editor.textView.needsDisplay = true
    }

    @objc func toggleBracketColorization(_ sender: Any?) {
        Preferences.shared.bracketPairColorization = !Preferences.shared.bracketPairColorization
    }

    @objc func toggleStickyScroll(_ sender: Any?) {
        let prefs = Preferences.shared
        prefs.stickyScroll = !prefs.stickyScroll
        if !prefs.stickyScroll {
            stickyScroll.isHidden = true
        } else {
            stickyScroll.updateStickyLines()
        }
    }

    @objc func toggleInlineDiagnostics(_ sender: Any?) {
        let prefs = Preferences.shared
        prefs.inlineDiagnostics = !prefs.inlineDiagnostics
        // Re-apply diagnostics to reflect the change
        editor.updateDiagnostics(editor.diagnostics)
    }

    @objc func togglePinCurrentTab(_ sender: Any?) {
        let index = project.tabManager.selectedIndex
        guard index >= 0 else { return }
        project.tabManager.togglePin(at: index)
        refreshEditor()
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

    // MARK: - Find / Replace Bar

    @objc func showFindBar(_ sender: Any?) {
        showFindBar(withReplace: false, initialText: selectedTextForFind())
    }

    @objc func showFindAndReplace(_ sender: Any?) {
        showFindBar(withReplace: true, initialText: selectedTextForFind())
    }

    private func showFindBar(withReplace: Bool, initialText: String?) {
        findReplaceBar.isHidden = false
        findReplaceBar.show(withReplace: withReplace, initialText: initialText)
        findBarHeightConstraint.constant = findReplaceBar.barHeight
        view.needsLayout = true
    }

    @objc func findNext(_ sender: Any?) {
        if findReplaceBar.isHidden {
            // Use occurrence navigation if find bar is not open
            editor.nextOccurrence(sender)
        } else {
            editor.navigateFind(direction: .next)
            findReplaceBar.updateCurrentMatchIndex(cursorLocation: editor.textView.selectedRange().location)
        }
    }

    @objc func findPrevious(_ sender: Any?) {
        if findReplaceBar.isHidden {
            editor.previousOccurrence(sender)
        } else {
            editor.navigateFind(direction: .previous)
            findReplaceBar.updateCurrentMatchIndex(cursorLocation: editor.textView.selectedRange().location)
        }
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        let text = selectedTextForFind()
        if let text = text, !text.isEmpty {
            showFindBar(withReplace: false, initialText: text)
        }
    }

    private func selectedTextForFind() -> String? {
        let sel = editor.textView.selectedRange()
        guard sel.length > 0, sel.length < 500 else { return nil }
        return (editor.textView.string as NSString).substring(with: sel)
    }

    @objc func sortImports(_ sender: Any?) {
        editor.sortImports(sender)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        editor.toggleBookmark(sender)
    }

    @objc func nextBookmark(_ sender: Any?) {
        editor.nextBookmark(sender)
    }

    @objc func previousBookmark(_ sender: Any?) {
        editor.previousBookmark(sender)
    }

    @objc func clearBookmarks(_ sender: Any?) {
        editor.clearBookmarks(sender)
    }

    @objc func pasteFromHistory(_ sender: Any?) {
        editor.pasteFromHistory(sender)
    }

    @objc func nextOccurrence(_ sender: Any?) {
        editor.nextOccurrence(sender)
    }

    @objc func previousOccurrence(_ sender: Any?) {
        editor.previousOccurrence(sender)
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

    @objc func transformToUppercase(_ sender: Any?) {
        editor.transformToUppercase(sender)
    }

    @objc func transformToLowercase(_ sender: Any?) {
        editor.transformToLowercase(sender)
    }

    @objc func transformToTitleCase(_ sender: Any?) {
        editor.transformToTitleCase(sender)
    }

    @objc func formatDocument(_ sender: Any?) {
        editor.formatDocument(sender)
    }

    @objc func jumpToDefinition(_ sender: Any?) {
        editor.jumpToDefinitionAction(sender)
    }

    @objc func jumpToMatchingBracket(_ sender: Any?) {
        editor.jumpToMatchingBracket(sender)
    }

    @objc func showQuickActions(_ sender: Any?) {
        editor.showQuickActions(sender)
    }

    @objc func sendToClaude(_ sender: Any?) {
        editor.sendToClaudeAction(sender)
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        editor.selectNextOccurrence(sender)
    }

    @objc func selectEnclosingBrackets(_ sender: Any?) {
        editor.selectEnclosingBrackets(sender)
    }

    @objc func jumpToNextIssue(_ sender: Any?) {
        editor.jumpToNextIssue(sender)
    }

    @objc func jumpToPreviousIssue(_ sender: Any?) {
        editor.jumpToPreviousIssue(sender)
    }

    @objc func showDocumentSymbols(_ sender: Any?) {
        guard let doc = project.tabManager.currentDocument else { return }
        Task {
            let symbols = (try? await project.lspClient.documentSymbols(url: doc.url)) ?? []
            await MainActor.run {
                guard !symbols.isEmpty else { return }
                let menu = NSMenu()
                self.addSymbolItems(symbols, to: menu, indent: 0)
                // Show the menu at the jump bar location
                let pt = NSPoint(x: self.jumpBar.frame.minX + 10, y: self.jumpBar.frame.maxY)
                menu.popUp(positioning: nil, at: pt, in: self.view)
            }
        }
    }

    private func addSymbolItems(_ symbols: [LSPDocumentSymbol], to menu: NSMenu, indent: Int) {
        for sym in symbols {
            let prefix = String(repeating: "  ", count: indent)
            let icon = symbolIcon(for: sym.kind)
            let item = NSMenuItem(title: "\(prefix)\(icon) \(sym.name)", action: #selector(symbolItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [sym.selectionRange.start.line, sym.selectionRange.start.character]
            menu.addItem(item)

            if let children = sym.children, !children.isEmpty {
                addSymbolItems(children, to: menu, indent: indent + 1)
            }
        }
    }

    @objc private func symbolItemSelected(_ sender: NSMenuItem) {
        guard let coords = sender.representedObject as? [Int], coords.count == 2 else { return }
        editor.scrollToLine(coords[0], column: coords[1])
    }

    private func symbolIcon(for kind: Int) -> String {
        switch kind {
        case 5: return "C"
        case 6: return "M"
        case 9: return "C"
        case 10: return "E"
        case 11: return "I"
        case 12: return "F"
        case 13: return "V"
        case 14: return "K"
        case 23: return "S"
        case 8: return "P"
        case 22: return "E"
        default: return "·"
        }
    }

    @objc func moveLineUp(_ sender: Any?) {
        editor.moveLineUp(sender)
    }

    @objc func moveLineDown(_ sender: Any?) {
        editor.moveLineDown(sender)
    }

    @objc func duplicateLine(_ sender: Any?) {
        editor.duplicateLine(sender)
    }

    @objc func deleteLine(_ sender: Any?) {
        editor.deleteLine(sender)
    }

    @objc override func selectLine(_ sender: Any?) {
        editor.selectLine(sender)
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        let index = project.tabManager.selectedIndex
        guard index >= 0 else { return }
        project.tabManager.closeOthers(keepingIndex: index)
        refreshEditor()
    }

    @objc func joinLines(_ sender: Any?) {
        editor.joinLines(sender)
    }

    @objc func insertLineAbove(_ sender: Any?) {
        editor.insertLineAbove(sender)
    }

    @objc func insertLineBelow(_ sender: Any?) {
        editor.insertLineBelow(sender)
    }

    @objc func findReferences(_ sender: Any?) {
        editor.findReferences(sender)
    }

    private func showReferencesMenu(_ locations: [LSPLocation]) {
        guard !locations.isEmpty else { return }

        if locations.count == 1 {
            // Single reference — jump directly
            let loc = locations[0]
            if let url = URL(string: loc.uri) {
                windowController?.openFile(url, atLine: loc.range.start.line, column: loc.range.start.character)
            }
            return
        }

        let menu = NSMenu(title: "References")
        for (i, loc) in locations.enumerated() {
            guard let url = URL(string: loc.uri) else { continue }
            let relativePath: String
            let rootPath = project.rootURL.path + "/"
            if url.path.hasPrefix(rootPath) {
                relativePath = String(url.path.dropFirst(rootPath.count))
            } else {
                relativePath = url.lastPathComponent
            }
            let title = "\(relativePath):\(loc.range.start.line + 1)"
            let item = NSMenuItem(title: title, action: #selector(referenceItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.representedObject = loc
            menu.addItem(item)
        }

        // Show at cursor location
        let cursorRect = editor.textView.firstRect(forCharacterRange: editor.textView.selectedRange(), actualRange: nil)
        let localPoint = view.window?.convertFromScreen(cursorRect).origin ?? .zero
        let viewPoint = view.convert(localPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: view)
    }

    @objc private func referenceItemSelected(_ sender: NSMenuItem) {
        guard let loc = sender.representedObject as? LSPLocation,
              let url = URL(string: loc.uri) else { return }
        windowController?.openFile(url, atLine: loc.range.start.line, column: loc.range.start.character)
    }

    @objc func foldAtCursor(_ sender: Any?) {
        editor.foldAtCursor(sender)
    }

    @objc func unfoldAtCursor(_ sender: Any?) {
        editor.unfoldAtCursor(sender)
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

    // MARK: - Diagnostics

    func handleDiagnostics(url: URL, diagnostics: [LSPDiagnostic]) {
        guard let currentDoc = project.tabManager.currentDocument,
              currentDoc.url == url else { return }
        editor.updateDiagnostics(diagnostics)

        // Update status bar diagnostic count
        let errors = diagnostics.filter { $0.severity == 1 }.count
        let warnings = diagnostics.filter { $0.severity == 2 }.count
        statusBar.updateDiagnosticCount(errors: errors, warnings: warnings)
    }

    // MARK: - Apply Edits to External Documents

    /// Apply LSP text edits to a document that may not be the currently displayed one.
    private func applyTextEdits(_ edits: [LSPTextEdit], to doc: ForgeDocument) {
        let ts = doc.textStorage
        let text = ts.string as NSString

        // Sort in reverse to avoid offset invalidation
        let sorted = edits.sorted { a, b in
            if a.range.start.line != b.range.start.line {
                return a.range.start.line > b.range.start.line
            }
            return a.range.start.character > b.range.start.character
        }

        ts.beginEditing()
        for edit in sorted {
            guard let nsRange = edit.range.toNSRange(in: text) else { continue }
            ts.replaceCharacters(in: nsRange, with: edit.newText)
        }
        ts.endEditing()
        doc.isModified = true

        // If this is the currently displayed document, refresh the editor
        if doc === project.tabManager.currentDocument {
            refreshEditor()
        }
    }

    // MARK: - Navigation

    func scrollToLine(_ line: Int, column: Int, selectLength: Int = 0) {
        editor.scrollToLine(line, column: column, selectLength: selectLength)
    }

    // MARK: - Focus

    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    // MARK: - Save support

    func syncDocumentContent() {
        editor.syncDocumentContent()
    }

    /// Prompt user to save a modified document before closing.
    /// Returns true if OK to proceed (saved or discarded), false if user cancelled.
    private func promptSaveForClose(doc: ForgeDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(doc.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            try? doc.save()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
    // MARK: - Helpers

    private func formatFileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return ""
        }
        if size < 1024 {
            return "(\(size) B)"
        } else if size < 1024 * 1024 {
            return String(format: "(%.1f KB)", Double(size) / 1024)
        } else {
            return String(format: "(%.1f MB)", Double(size) / (1024 * 1024))
        }
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
