import AppKit

class MainSplitViewController: NSSplitViewController {

    let project: ForgeProject
    weak var windowController: MainWindowController?

    // Child view controllers
    private var navigatorVC: NavigatorViewController!
    private var editorContainerVC: EditorContainerViewController!
    private var bottomPanelVC: BottomPanelViewController!

    init(project: ForgeProject, windowController: MainWindowController) {
        self.project = project
        self.windowController = windowController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // We use a vertical split: top area (which itself is a horizontal split) + bottom panel
        // But NSSplitView can only split one axis. So we nest:
        // Outer: vertical (top, bottom)
        //   Top: horizontal (navigator, editor)

        // Create child controllers
        navigatorVC = NavigatorViewController(project: project, windowController: windowController)
        editorContainerVC = EditorContainerViewController(project: project)
        editorContainerVC.windowController = windowController
        bottomPanelVC = BottomPanelViewController()

        // Inner horizontal split for navigator + editor
        let horizontalSplit = NSSplitViewController()
        horizontalSplit.splitView.isVertical = true

        let navItem = NSSplitViewItem(sidebarWithViewController: navigatorVC)
        navItem.minimumThickness = 180
        navItem.maximumThickness = 400
        navItem.canCollapse = true
        navItem.holdingPriority = .defaultLow + 1
        horizontalSplit.addSplitViewItem(navItem)

        let editorItem = NSSplitViewItem(viewController: editorContainerVC)
        editorItem.minimumThickness = 300
        horizontalSplit.addSplitViewItem(editorItem)

        // Outer vertical split: horizontal area + bottom panel
        splitView.isVertical = false

        let topItem = NSSplitViewItem(viewController: horizontalSplit)
        topItem.minimumThickness = 200
        addSplitViewItem(topItem)

        let bottomItem = NSSplitViewItem(viewController: bottomPanelVC)
        bottomItem.minimumThickness = 100
        bottomItem.maximumThickness = 500
        bottomItem.canCollapse = true
        bottomItem.isCollapsed = true
        bottomItem.holdingPriority = .defaultLow + 2
        addSplitViewItem(bottomItem)

        splitView.dividerStyle = .thin

        // Wire up build log click-to-navigate
        bottomPanelVC.buildLogDelegate = self

        // Set project root for terminals
        bottomPanelVC.terminalView.setProjectRoot(project.rootURL)
        bottomPanelVC.claudeView.setProjectRoot(project.rootURL)
    }

    func editorAreaDidUpdate() {
        editorContainerVC.refreshEditor()
    }

    func syncDocumentContent() {
        editorContainerVC.syncDocumentContent()
    }

    func scrollToLine(_ line: Int, column: Int) {
        editorContainerVC.scrollToLine(line, column: column)
    }

    // MARK: - Reveal in Navigator (⌘⇧J)

    @objc func revealInNavigator(_ sender: Any?) {
        guard let currentDoc = project.tabManager.currentDocument else { return }

        // Make sure navigator is visible
        if let horizontalSplit = splitViewItems.first?.viewController as? NSSplitViewController,
           horizontalSplit.splitViewItems.first?.isCollapsed == true {
            horizontalSplit.splitViewItems.first?.animator().isCollapsed = false
        }

        navigatorVC.revealFile(url: currentDoc.url)
    }

    // MARK: - Panel toggles

    @objc func toggleNavigator(_ sender: Any?) {
        guard splitViewItems.count > 0 else { return }
        // The navigator is inside the first split view item's view controller (which is the horizontal split)
        if let horizontalSplit = splitViewItems[0].viewController as? NSSplitViewController,
           horizontalSplit.splitViewItems.count > 0 {
            let navItem = horizontalSplit.splitViewItems[0]
            navItem.animator().isCollapsed = !navItem.isCollapsed
        }
    }

    @objc func toggleBottomPanel(_ sender: Any?) {
        guard splitViewItems.count > 1 else { return }
        let bottomItem = splitViewItems[1]
        bottomItem.animator().isCollapsed = !bottomItem.isCollapsed
    }

    // MARK: - Build log

    func showBottomPanel() {
        guard splitViewItems.count > 1 else { return }
        let bottomItem = splitViewItems[1]
        if bottomItem.isCollapsed {
            bottomItem.animator().isCollapsed = false
        }
    }

    func showBuildLog() {
        showBottomPanel()
        bottomPanelVC.showBuildLog()
    }

    func appendBuildOutput(_ text: String) {
        bottomPanelVC.appendBuildOutput(text)
    }

    func clearBuildLog() {
        bottomPanelVC.clearBuildLog()
    }

    // MARK: - Find in Project (⌘⇧F)

    @objc func findInProject(_ sender: Any?) {
        showBottomPanel()
        bottomPanelVC.searchResultsView.setProjectRoot(project.rootURL)
        bottomPanelVC.searchResultsView.delegate = self
        bottomPanelVC.showSearch()
    }
}

extension MainSplitViewController: SearchResultsViewDelegate {
    func searchResultsView(_ view: SearchResultsView, didSelectResult result: SearchResult) {
        windowController?.openFile(result.url, atLine: result.line - 1, column: result.column - 1)
    }
}

extension MainSplitViewController: BuildLogViewDelegate {
    func buildLogView(_ view: BuildLogView, didClickFileReference url: URL, line: Int, column: Int) {
        windowController?.openFile(url, atLine: line, column: column)
    }
}
