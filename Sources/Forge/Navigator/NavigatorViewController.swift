import AppKit

class NavigatorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    private let project: ForgeProject
    private weak var windowController: MainWindowController?
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private let filterField = NSSearchField()
    private var rootNode: FileNode?
    private var fileWatcher: FileSystemWatcher?
    private var filterText: String = ""

    init(project: ForgeProject, windowController: MainWindowController?) {
        self.project = project
        self.windowController = windowController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0).cgColor

        // Filter field at top
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.placeholderString = "Filter"
        filterField.font = NSFont.systemFont(ofSize: 12)
        filterField.focusRingType = .none
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        container.addSubview(filterField)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        outlineView = NavigatorOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 22
        outlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineViewDoubleClicked(_:))

        scrollView.documentView = outlineView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            filterField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            filterField.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadFileTree()
        startFileWatcher()
        setupContextMenu()
        refreshGitStatus()
    }

    private func refreshGitStatus() {
        project.gitStatus.refresh { [weak self] in
            self?.outlineView.reloadData()
        }
    }

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
    }

    private func startFileWatcher() {
        fileWatcher = FileSystemWatcher(path: project.rootURL.path, debounceInterval: 0.8) { [weak self] changedPaths in
            self?.reloadFileTree()
            self?.refreshGitStatus()
            // Check if any open documents were modified externally
            // Only check documents whose files actually changed
            self?.checkOpenDocuments(changedPaths: changedPaths)
        }
        fileWatcher?.start()
    }

    private func checkOpenDocuments(changedPaths: [String]) {
        guard !changedPaths.isEmpty else { return }
        let changedURLs = Set(changedPaths.map { URL(fileURLWithPath: $0) })
        let hasOpenChanged = project.tabManager.tabs.contains { tab in
            changedURLs.contains(tab.url)
        }
        if hasOpenChanged {
            windowController?.checkForExternalChanges()
        }
    }

    /// Reload the file tree while preserving expanded state
    func reloadFileTree() {
        guard let root = rootNode else { return }

        // Collect currently expanded items
        var expandedURLs = Set<URL>()
        collectExpandedURLs(root, into: &expandedURLs)

        // Remember selected item
        let selectedRow = outlineView.selectedRow
        var selectedURL: URL?
        if selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? FileNode {
            selectedURL = node.url
        }

        // Reload from disk
        let newRoot = FileNode(url: project.rootURL, isDirectory: true)
        newRoot.projectRoot = project.rootURL

        let gitignoreURL = project.rootURL.appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignoreURL.path) {
            newRoot.gitignore = GitignoreParser(gitignoreURL: gitignoreURL)
        }

        newRoot.loadChildren()
        rootNode = newRoot

        outlineView.reloadData()
        outlineView.expandItem(rootNode)

        // Re-expand previously expanded items
        isAutoExpanding = true
        restoreExpandedState(newRoot, expandedURLs: expandedURLs)
        isAutoExpanding = false

        // Re-select previously selected item
        if let selectedURL = selectedURL {
            reselectNode(url: selectedURL)
        }
    }

    private func collectExpandedURLs(_ node: FileNode, into urls: inout Set<URL>) {
        if outlineView.isItemExpanded(node) {
            urls.insert(node.url)
            for child in node.children where child.isDirectory {
                collectExpandedURLs(child, into: &urls)
            }
        }
    }

    private func restoreExpandedState(_ node: FileNode, expandedURLs: Set<URL>) {
        for child in node.children where child.isDirectory && expandedURLs.contains(child.url) {
            child.loadChildren()
            outlineView.reloadItem(child, reloadChildren: true)
            outlineView.expandItem(child)
            restoreExpandedState(child, expandedURLs: expandedURLs)
        }
    }

    private func reselectNode(url: URL) {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.url == url {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            }
        }
    }

    private var isAutoExpanding = false

    private func loadFileTree() {
        rootNode = FileNode(url: project.rootURL, isDirectory: true)
        rootNode?.projectRoot = project.rootURL

        // Load .gitignore if it exists
        let gitignoreURL = project.rootURL.appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignoreURL.path) {
            rootNode?.gitignore = GitignoreParser(gitignoreURL: gitignoreURL)
        }

        rootNode?.loadChildren()

        // Pre-load children of key directories before telling the outline view
        preloadKeyDirectories(rootNode)

        outlineView.reloadData()
        outlineView.expandItem(rootNode)

        // Auto-expand key directories
        isAutoExpanding = true
        autoExpandKeyDirectories()
        isAutoExpanding = false
    }

    /// Pre-load children of Sources/, src/ etc. so data is ready before expand
    private func preloadKeyDirectories(_ node: FileNode?) {
        guard let node = node else { return }
        let expandNames: Set<String> = ["Sources", "src", "Source"]
        for child in node.children where child.isDirectory && expandNames.contains(child.name) {
            preloadSingleChildChain(child)
        }
    }

    private func preloadSingleChildChain(_ node: FileNode) {
        node.loadChildren()
        let dirChildren = node.children.filter(\.isDirectory)
        if dirChildren.count == 1 {
            preloadSingleChildChain(dirChildren[0])
        }
    }

    private func autoExpandKeyDirectories() {
        guard let root = rootNode else { return }
        let expandNames: Set<String> = ["Sources", "src", "Source"]
        for child in root.children where child.isDirectory && expandNames.contains(child.name) {
            expandSingleChildChain(child)
        }
    }

    private func expandSingleChildChain(_ node: FileNode) {
        outlineView.expandItem(node)
        let dirChildren = node.children.filter(\.isDirectory)
        if dirChildren.count == 1 {
            expandSingleChildChain(dirChildren[0])
        }
    }

    // MARK: - Filter

    @objc private func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue.lowercased()
        outlineView.reloadData()

        if !filterText.isEmpty {
            // Auto-expand all visible directories when filtering
            expandAllVisible(rootNode)
        }
    }

    private func expandAllVisible(_ node: FileNode?) {
        guard let node = node else { return }
        for child in filteredChildren(of: node) where child.isDirectory {
            outlineView.expandItem(child)
            expandAllVisible(child)
        }
    }

    /// Collapse all expanded directories in the navigator
    @objc func collapseAll(_ sender: Any? = nil) {
        guard let root = rootNode else { return }
        collapseAllChildren(root)
    }

    private func collapseAllChildren(_ node: FileNode) {
        for child in node.children where child.isDirectory {
            collapseAllChildren(child)
            outlineView.collapseItem(child)
        }
    }

    private func filteredChildren(of node: FileNode) -> [FileNode] {
        guard !filterText.isEmpty else { return node.children }
        return node.children.filter { nodeMatchesFilter($0) }
    }

    private func nodeMatchesFilter(_ node: FileNode) -> Bool {
        // File matches via fuzzy match against its name
        if FuzzyMatch.match(pattern: filterText, candidate: node.name) != nil {
            return true
        }
        // Directory matches if any descendant matches
        if node.isDirectory {
            return node.children.contains { nodeMatchesFilter($0) }
        }
        return false
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            guard let root = rootNode else { return 0 }
            return filteredChildren(of: root).count
        }
        guard let node = item as? FileNode else { return 0 }
        return filteredChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil, let root = rootNode {
            return filteredChildren(of: root)[index]
        }
        guard let node = item as? FileNode else { return NSNull() }
        return filteredChildren(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory && !filteredChildren(of: node).isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Show modified indicator (dot) for files with unsaved changes
        let isUnsaved = project.tabManager.tabs.contains { $0.url == node.url && $0.isModified }
        cell.textField?.stringValue = isUnsaved ? "● \(node.name)" : node.name
        cell.imageView?.image = node.icon

        // Git status coloring
        if let status = project.gitStatus.status(for: node.url) {
            switch status {
            case .modified:
                cell.textField?.textColor = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)
            case .added, .untracked:
                cell.textField?.textColor = NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1.0)
            case .deleted:
                cell.textField?.textColor = NSColor(red: 0.90, green: 0.40, blue: 0.40, alpha: 1.0)
            case .conflict:
                cell.textField?.textColor = NSColor(red: 0.99, green: 0.30, blue: 0.30, alpha: 1.0)
            case .renamed:
                cell.textField?.textColor = NSColor(red: 0.50, green: 0.70, blue: 0.95, alpha: 1.0)
            }
        } else if node.isDirectory && project.gitStatus.hasChanges(under: node.url) {
            cell.textField?.textColor = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)
        } else {
            cell.textField?.textColor = .labelColor
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        if !node.isDirectory {
            windowController?.openFileAsPreview(node.url)
        }
    }

    @objc private func outlineViewDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        if !node.isDirectory {
            // Double-click opens as permanent tab (not preview)
            windowController?.openFile(node.url)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isAutoExpanding,
              let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        node.loadChildren()
        outlineView.reloadItem(node, reloadChildren: true)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        let clickedNode = clickedRow >= 0 ? outlineView.item(atRow: clickedRow) as? FileNode : nil

        // Select the clicked row so the user sees what they right-clicked
        if clickedRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        // Determine the parent directory for new file/folder
        let targetDir: URL
        if let node = clickedNode {
            targetDir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        } else {
            targetDir = project.rootURL
        }

        let newFileItem = NSMenuItem(title: "New File…", action: #selector(newFileAction(_:)), keyEquivalent: "")
        newFileItem.target = self
        newFileItem.representedObject = targetDir
        menu.addItem(newFileItem)

        let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(newFolderAction(_:)), keyEquivalent: "")
        newFolderItem.target = self
        newFolderItem.representedObject = targetDir
        menu.addItem(newFolderItem)

        if let node = clickedNode {
            menu.addItem(.separator())

            let renameItem = NSMenuItem(title: "Rename…", action: #selector(renameAction(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = node
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAction(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = node
            menu.addItem(deleteItem)

            menu.addItem(.separator())

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinderAction(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = node
            menu.addItem(revealItem)

            menu.addItem(.separator())

            let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathAction(_:)), keyEquivalent: "")
            copyPathItem.target = self
            copyPathItem.representedObject = node
            menu.addItem(copyPathItem)

            let copyRelativePathItem = NSMenuItem(title: "Copy Relative Path", action: #selector(copyRelativePathAction(_:)), keyEquivalent: "")
            copyRelativePathItem.target = self
            copyRelativePathItem.representedObject = node
            menu.addItem(copyRelativePathItem)

            menu.addItem(.separator())

            let openTerminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(openInTerminalAction(_:)), keyEquivalent: "")
            openTerminalItem.target = self
            openTerminalItem.representedObject = node
            menu.addItem(openTerminalItem)

            if !node.isDirectory {
                let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicateAction(_:)), keyEquivalent: "")
                duplicateItem.target = self
                duplicateItem.representedObject = node
                menu.addItem(duplicateItem)
            }
        }
    }

    @objc private func newFileAction(_ sender: NSMenuItem) {
        guard let parentURL = sender.representedObject as? URL else { return }
        promptForName(title: "New File", message: "Enter the file name:") { name in
            let fileURL = parentURL.appendingPathComponent(name)
            let template = Self.templateContent(for: fileURL.pathExtension, fileName: name)
            if !FileManager.default.createFile(atPath: fileURL.path, contents: template.data(using: .utf8)) {
                self.showFileError("Could not create file \"\(name)\".")
                return
            }
            self.reloadFileTree()
            self.windowController?.openFile(fileURL)
        }
    }

    /// Returns template content for a new file based on its extension
    private static func templateContent(for ext: String, fileName: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        switch ext.lowercased() {
        case "swift":
            return "import Foundation\n\n"
        case "h":
            let guard_ = baseName.uppercased() + "_H"
            return "#ifndef \(guard_)\n#define \(guard_)\n\n\n\n#endif /* \(guard_) */\n"
        case "c", "m":
            return "#include \"\(baseName).h\"\n\n"
        case "py":
            return "#!/usr/bin/env python3\n\n"
        case "sh", "bash":
            return "#!/bin/bash\n\n"
        case "zsh":
            return "#!/bin/zsh\n\n"
        case "html", "htm":
            return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"UTF-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n    <title>\(baseName)</title>\n</head>\n<body>\n    \n</body>\n</html>\n"
        case "json":
            return "{\n    \n}\n"
        case "yaml", "yml":
            return "---\n"
        case "xml":
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        case "rb":
            return "# frozen_string_literal: true\n\n"
        case "rs":
            return "fn main() {\n    \n}\n"
        case "go":
            return "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello\")\n}\n"
        default:
            return ""
        }
    }

    @objc private func newFolderAction(_ sender: NSMenuItem) {
        guard let parentURL = sender.representedObject as? URL else { return }
        promptForName(title: "New Folder", message: "Enter the folder name:") { name in
            let folderURL = parentURL.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            } catch {
                self.showFileError("Could not create folder \"\(name)\": \(error.localizedDescription)")
                return
            }
            self.reloadFileTree()
        }
    }

    @objc private func renameAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        promptForName(title: "Rename", message: "Enter the new name:", defaultValue: node.name) { name in
            let newURL = node.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: node.url, to: newURL)
            } catch {
                self.showFileError("Could not rename \"\(node.name)\": \(error.localizedDescription)")
                return
            }
            self.reloadFileTree()
        }
    }

    @objc private func deleteAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(node.name)\"?"
        alert.informativeText = node.isDirectory
            ? "This folder and all its contents will be moved to the Trash."
            : "This file will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            showFileError("Could not delete \"\(node.name)\": \(error.localizedDescription)")
            return
        }
        reloadFileTree()
    }

    @objc private func revealInFinderAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func copyRelativePathAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let rootPath = project.rootURL.path
        let nodePath = node.url.path
        let relativePath = nodePath.hasPrefix(rootPath)
            ? String(nodePath.dropFirst(rootPath.count + 1))
            : nodePath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePath, forType: .string)
    }

    @objc private func openInTerminalAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", dir.path]
        try? process.run()
    }

    @objc private func duplicateAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, !node.isDirectory else { return }
        let dir = node.url.deletingLastPathComponent()
        let name = node.url.deletingPathExtension().lastPathComponent
        let ext = node.url.pathExtension

        // Generate unique name: "file copy.ext", "file copy 2.ext", etc.
        var copyName = ext.isEmpty ? "\(name) copy" : "\(name) copy.\(ext)"
        var copyURL = dir.appendingPathComponent(copyName)
        var counter = 2
        while FileManager.default.fileExists(atPath: copyURL.path) {
            copyName = ext.isEmpty ? "\(name) copy \(counter)" : "\(name) copy \(counter).\(ext)"
            copyURL = dir.appendingPathComponent(copyName)
            counter += 1
        }

        do {
            try FileManager.default.copyItem(at: node.url, to: copyURL)
        } catch {
            showFileError("Could not duplicate \"\(node.name)\": \(error.localizedDescription)")
            return
        }
        reloadFileTree()
    }

    private func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Operation Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func promptForName(title: String, message: String, defaultValue: String = "", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        completion(name)
    }

    // MARK: - Reveal in Navigator (⌘⇧J)

    func revealFile(url: URL) {
        guard let root = rootNode else { return }

        // Build the path from root to the target file
        let rootPath = root.url.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path

        guard filePath.hasPrefix(rootPath) else { return }

        let relativePath = String(filePath.dropFirst(rootPath.count))
        let components = relativePath.split(separator: "/").map(String.init)

        var currentNode = root
        var nodePath: [FileNode] = []

        for component in components {
            currentNode.loadChildren()
            guard let child = currentNode.children.first(where: { $0.name == component }) else {
                return
            }
            nodePath.append(child)
            currentNode = child
        }

        // Expand all ancestor directories
        isAutoExpanding = true
        for node in nodePath.dropLast() {
            node.loadChildren()
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        }
        isAutoExpanding = false

        // Select and scroll to the file
        let row = outlineView.row(forItem: currentNode)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    // MARK: - Keyboard Actions (called from NavigatorOutlineView)

    func deleteSelectedFile() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        // Reuse deleteAction logic
        let fakeMenuItem = NSMenuItem()
        fakeMenuItem.representedObject = node
        deleteAction(fakeMenuItem)
    }

    func renameSelectedFile() {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        let fakeMenuItem = NSMenuItem()
        fakeMenuItem.representedObject = node
        renameAction(fakeMenuItem)
    }
}

// MARK: - Custom Outline View with Keyboard Handling

/// NSOutlineView subclass that forwards Delete and Enter keys to the navigator.
private class NavigatorOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        // Delete or Backspace → trash selected item
        if event.keyCode == 51 || event.keyCode == 117 { // Backspace or Forward Delete
            if let nav = delegate as? NavigatorViewController {
                nav.deleteSelectedFile()
                return
            }
        }

        // Enter (Return) → rename selected item
        if event.keyCode == 36 { // Return key
            if let nav = delegate as? NavigatorViewController {
                nav.renameSelectedFile()
                return
            }
        }

        super.keyDown(with: event)
    }
}
