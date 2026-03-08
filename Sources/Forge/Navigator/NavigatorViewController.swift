import AppKit

class NavigatorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let project: ForgeProject
    private weak var windowController: MainWindowController?
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootNode: FileNode?

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

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        outlineView = NSOutlineView()
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

        scrollView.documentView = outlineView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadFileTree()

        // Refresh when app becomes active (catches external file changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        reloadFileTree()
    }

    /// Reload the file tree while preserving expanded state
    func reloadFileTree() {
        guard let root = rootNode else { return }

        // Collect currently expanded items
        var expandedURLs = Set<URL>()
        collectExpandedURLs(root, into: &expandedURLs)

        // Reload
        let newRoot = FileNode(url: project.rootURL, isDirectory: true)
        newRoot.loadChildren()
        rootNode = newRoot

        outlineView.reloadData()
        outlineView.expandItem(rootNode)

        // Re-expand previously expanded items
        isAutoExpanding = true
        restoreExpandedState(newRoot, expandedURLs: expandedURLs)
        isAutoExpanding = false
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

    private var isAutoExpanding = false

    private func loadFileTree() {
        rootNode = FileNode(url: project.rootURL, isDirectory: true)
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

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode?.children.count ?? 0
        }
        guard let node = item as? FileNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!.children[index]
        }
        let node = item as! FileNode
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory
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

        cell.textField?.stringValue = node.name
        cell.imageView?.image = node.icon

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        if !node.isDirectory {
            windowController?.openFile(node.url)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isAutoExpanding,
              let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        node.loadChildren()
        outlineView.reloadItem(node, reloadChildren: true)
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
}
