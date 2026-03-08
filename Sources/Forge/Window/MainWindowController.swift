import AppKit

class MainWindowController: NSWindowController, NSWindowDelegate, OpenQuicklyDelegate, NSToolbarDelegate {

    let project: ForgeProject
    private var splitViewController: MainSplitViewController!
    private var openQuicklyController: OpenQuicklyWindowController?
    private var autoSaveTimer: Timer?

    init(project: ForgeProject) {
        self.project = project

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = project.displayName
        window.subtitle = project.rootURL.path
        window.minSize = NSSize(width: 600, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)

        // Window frame autosave
        window.setFrameAutosaveName("ForgeMainWindow-\(project.rootURL.lastPathComponent)")

        super.init(window: window)
        window.delegate = self

        setupToolbar(window)

        splitViewController = MainSplitViewController(project: project, windowController: self)
        window.contentViewController = splitViewController

        // Only set default frame if no saved frame was restored
        if !window.setFrameUsingName(window.frameAutosaveName) {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1100)
            let windowWidth = max(1440, screenFrame.width * 0.80)
            let windowHeight = max(900, screenFrame.height * 0.80)
            let origin = NSPoint(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.origin.y + (screenFrame.height - windowHeight) / 2,
            )
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: windowWidth, height: windowHeight), display: true)
        }

        restoreOpenTabs()
        if project.tabManager.tabs.isEmpty {
            openInitialFile()
        }

        // Auto-save modified documents every 30 seconds
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.autoSaveAll()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Toolbar

    private static let toolbarBackForward = NSToolbarItem.Identifier("backForward")
    private static let toolbarRun = NSToolbarItem.Identifier("run")
    private static let toolbarStop = NSToolbarItem.Identifier("stop")
    private static let toolbarBuild = NSToolbarItem.Identifier("build")

    private func setupToolbar(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ForgeMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarBackForward, .flexibleSpace, Self.toolbarBuild, Self.toolbarRun, Self.toolbarStop]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toolbarBackForward:
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)

            let backItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("back"))
            backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            backItem.label = "Back"
            backItem.action = #selector(goBack(_:))
            backItem.target = self

            let forwardItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("forward"))
            forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            forwardItem.label = "Forward"
            forwardItem.action = #selector(goForward(_:))
            forwardItem.target = self

            group.subitems = [backItem, forwardItem]
            group.selectionMode = .momentary
            group.controlRepresentation = .automatic
            group.label = "Navigation"
            return group

        case Self.toolbarBuild:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Build")
            item.label = "Build"
            item.toolTip = "Build (⌘B)"
            item.action = #selector(buildProject(_:))
            item.target = self
            return item

        case Self.toolbarRun:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run")
            item.label = "Run"
            item.toolTip = "Run (⌘R)"
            item.action = #selector(runProject(_:))
            item.target = self
            return item

        case Self.toolbarStop:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
            item.label = "Stop"
            item.toolTip = "Stop (⌘.)"
            item.action = #selector(stopBuild(_:))
            item.target = self
            return item

        default:
            return nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let unsavedDocs = project.tabManager.tabs.filter(\.isModified)
        guard !unsavedDocs.isEmpty else { return true }

        // Sync current document
        splitViewController.syncDocumentContent()

        if unsavedDocs.count == 1 {
            let doc = unsavedDocs[0].document
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
        } else {
            let alert = NSAlert()
            alert.messageText = "You have \(unsavedDocs.count) unsaved documents."
            alert.informativeText = "Do you want to save all changes before closing?"
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Discard All")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                for tab in unsavedDocs {
                    try? tab.document.save()
                }
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - File operations

    func openFile(_ url: URL) {
        let doc = project.document(for: url)
        project.tabManager.openOrFocus(document: doc)
        project.navigationHistory.push(url: url)
        splitViewController.editorAreaDidUpdate()

        // Track in recent documents
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Open a file as a preview tab (replaces existing preview, shown in italics)
    func openFileAsPreview(_ url: URL) {
        let doc = project.document(for: url)
        project.tabManager.openPreview(document: doc)
        project.navigationHistory.push(url: url)
        splitViewController.editorAreaDidUpdate()
    }

    /// Open a file and scroll to a specific line/column (0-based, LSP convention)
    func openFile(_ url: URL, atLine line: Int, column: Int, selectLength: Int = 0) {
        openFile(url)
        splitViewController.scrollToLine(line, column: column, selectLength: selectLength)
    }

    func saveCurrentDocument() {
        guard let doc = project.tabManager.currentDocument else { return }
        // Sync editor text back to document before saving
        splitViewController.syncDocumentContent()
        try? doc.save()
        project.lspClient.didSave(url: doc.url)
        splitViewController.editorAreaDidUpdate()

        if let window = window {
            window.isDocumentEdited = false
        }
    }

    func saveAllDocuments() {
        splitViewController.syncDocumentContent()
        for tab in project.tabManager.tabs where tab.isModified {
            try? tab.document.save()
            project.lspClient.didSave(url: tab.document.url)
        }
        splitViewController.editorAreaDidUpdate()
        if let window = window {
            window.isDocumentEdited = false
        }
    }

    /// Auto-save modified documents (called on app deactivation)
    func autoSaveAll() {
        splitViewController.syncDocumentContent()
        for tab in project.tabManager.tabs where tab.isModified {
            try? tab.document.save()
        }
        // Don't refresh editor — just save silently
    }

    // MARK: - External file change detection

    func checkForExternalChanges() {
        var reloadedCurrent = false

        for tab in project.tabManager.tabs {
            let doc = tab.document
            guard doc.hasChangedOnDisk() else { continue }

            if doc.isModified {
                // Document has local edits AND disk changes — prompt
                let alert = NSAlert()
                alert.messageText = "\(doc.fileName) has been modified externally."
                alert.informativeText = "Do you want to reload from disk? Your unsaved changes will be lost."
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Keep Mine")
                alert.alertStyle = .warning

                if alert.runModal() == .alertFirstButtonReturn {
                    doc.loadFromDisk()
                    if doc === project.tabManager.currentDocument {
                        reloadedCurrent = true
                    }
                }
            } else {
                // No local edits — silently reload
                doc.loadFromDisk()
                if doc === project.tabManager.currentDocument {
                    reloadedCurrent = true
                }
            }
        }

        if reloadedCurrent {
            splitViewController.editorAreaDidUpdate()
        }
    }

    // MARK: - Tab actions

    @objc func closeCurrentTab(_ sender: Any?) {
        guard let doc = project.tabManager.currentDocument else { return }

        if doc.isModified {
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
                saveCurrentDocument()
                project.tabManager.closeCurrent()
                splitViewController.editorAreaDidUpdate()
            case .alertSecondButtonReturn: // Don't Save
                project.tabManager.closeCurrent()
                splitViewController.editorAreaDidUpdate()
            default: // Cancel
                return
            }
        } else {
            project.tabManager.closeCurrent()
            splitViewController.editorAreaDidUpdate()
        }
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        project.tabManager.selectPrevious()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func selectNextTab(_ sender: Any?) {
        project.tabManager.selectNext()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let tabNumber = sender.tag // 1-based
        let index = tabNumber - 1
        guard index >= 0 && index < project.tabManager.tabs.count else { return }
        project.tabManager.select(at: index)
        splitViewController.editorAreaDidUpdate()
    }

    @objc func reopenLastTab(_ sender: Any?) {
        project.tabManager.reopenLast()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func switchToMostRecentTab(_ sender: Any?) {
        project.tabManager.switchToMostRecent()
        splitViewController.editorAreaDidUpdate()
    }

    // MARK: - Build

    @objc func buildProject(_ sender: Any?) {
        splitViewController.showBuildLog()
        splitViewController.clearBuildLog()

        let buildSystem = project.buildSystem
        buildSystem.onOutput = { [weak self] text in
            self?.splitViewController.appendBuildOutput(text)
        }
        buildSystem.onComplete = { [weak self] success in
            let msg = success ? "Build succeeded.\n" : "Build failed.\n"
            self?.splitViewController.appendBuildOutput(msg)
        }

        splitViewController.appendBuildOutput("Building \(project.displayName)...\n\n")
        buildSystem.build()
    }

    @objc func runProject(_ sender: Any?) {
        splitViewController.showBuildLog()
        splitViewController.clearBuildLog()

        let buildSystem = project.buildSystem
        buildSystem.onOutput = { [weak self] text in
            self?.splitViewController.appendBuildOutput(text)
        }
        buildSystem.onComplete = { [weak self] success in
            let msg = success ? "Run completed.\n" : "Run failed.\n"
            self?.splitViewController.appendBuildOutput(msg)
        }

        splitViewController.appendBuildOutput("Building and running \(project.displayName)...\n\n")
        buildSystem.buildAndRun()
    }

    @objc func cleanBuild(_ sender: Any?) {
        splitViewController.showBuildLog()
        splitViewController.clearBuildLog()

        let buildSystem = project.buildSystem
        buildSystem.onOutput = { [weak self] text in
            self?.splitViewController.appendBuildOutput(text)
        }
        buildSystem.onComplete = { [weak self] success in
            let msg = success ? "Clean complete.\n" : "Clean failed.\n"
            self?.splitViewController.appendBuildOutput(msg)
        }

        splitViewController.appendBuildOutput("Cleaning \(project.displayName)...\n\n")
        buildSystem.clean()
    }

    @objc func stopBuild(_ sender: Any?) {
        project.buildSystem.cancel()
        splitViewController.appendBuildOutput("\nBuild cancelled.\n")
    }

    // MARK: - Navigation History

    @objc func goBack(_ sender: Any?) {
        guard let entry = project.navigationHistory.goBack() else { return }
        let doc = project.document(for: entry.url)
        project.tabManager.openOrFocus(document: doc)
        splitViewController.editorAreaDidUpdate()
    }

    @objc func goForward(_ sender: Any?) {
        guard let entry = project.navigationHistory.goForward() else { return }
        let doc = project.document(for: entry.url)
        project.tabManager.openOrFocus(document: doc)
        splitViewController.editorAreaDidUpdate()
    }

    // MARK: - Focus Editor

    @objc func focusEditor(_ sender: Any?) {
        splitViewController.focusEditor()
    }

    // MARK: - Open Quickly

    @objc func showOpenQuickly(_ sender: Any?) {
        guard let win = window else { return }
        if openQuicklyController == nil {
            openQuicklyController = OpenQuicklyWindowController(projectRoot: project.rootURL)
            openQuicklyController?.delegate = self
            openQuicklyController?.lspClient = project.lspClient
        }
        openQuicklyController?.showInWindow(win)
    }

    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL) {
        openFile(url)
    }

    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL, atLine line: Int, column: Int) {
        if url.path.isEmpty {
            // Just ":line" — navigate in current file
            splitViewController.scrollToLine(line, column: column)
        } else {
            openFile(url, atLine: line, column: column)
        }
    }

    // MARK: - Tab State Persistence

    private var tabStateKey: String {
        "ForgeOpenTabs-\(project.rootURL.path.hashValue)"
    }

    func saveOpenTabs() {
        let urls = project.tabManager.tabs.map { $0.url.path }
        let selectedIndex = project.tabManager.selectedIndex
        let state: [String: Any] = [
            "files": urls,
            "selected": selectedIndex,
        ]
        UserDefaults.standard.set(state, forKey: tabStateKey)
    }

    private func restoreOpenTabs() {
        guard let state = UserDefaults.standard.dictionary(forKey: tabStateKey),
              let files = state["files"] as? [String],
              let selected = state["selected"] as? Int else { return }

        for path in files {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let doc = project.document(for: url)
            project.tabManager.openOrFocus(document: doc)
        }

        if selected >= 0 && selected < project.tabManager.tabs.count {
            project.tabManager.select(at: selected)
        }

        splitViewController.editorAreaDidUpdate()
    }

    // MARK: - NSWindowDelegate — save state on close

    func windowWillClose(_ notification: Notification) {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        saveOpenTabs()
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    // MARK: - Initial file

    private func openInitialFile() {
        // Find a good initial .swift file — prefer files under Sources/ over Package.swift
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: project.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var fallback: URL?
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" && !url.lastPathComponent.hasPrefix(".") {
                // Prefer source files over Package.swift
                if url.lastPathComponent == "Package.swift" {
                    fallback = fallback ?? url
                } else {
                    openFile(url)
                    return
                }
            }
        }
        if let url = fallback {
            openFile(url)
        }
    }
}
