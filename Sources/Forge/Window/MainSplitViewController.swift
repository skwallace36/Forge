import AppKit

class MainSplitViewController: NSSplitViewController {

    let project: ForgeProject
    weak var windowController: MainWindowController?

    // Child view controllers
    private var navigatorVC: NavigatorViewController!
    private var editorContainerVC: EditorContainerViewController!
    private var inspectorVC: InspectorViewController!
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
        inspectorVC = InspectorViewController()
        inspectorVC.lspClient = project.lspClient
        bottomPanelVC = BottomPanelViewController()

        // Wire up send to Claude
        editorContainerVC.onSendToClaude = { [weak self] code, fileName, line in
            self?.bottomPanelVC.sendCodeToClaude(code, fileName: fileName, line: line)
        }

        // Wire up cursor changes → inspector Quick Help
        editorContainerVC.onCursorPositionChange = { [weak self] url, line, column in
            self?.inspectorVC.updateQuickHelp(url: url, line: line, character: column)
        }

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

        let inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        inspectorItem.minimumThickness = 200
        inspectorItem.maximumThickness = 350
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        inspectorItem.holdingPriority = .defaultLow + 1
        horizontalSplit.addSplitViewItem(inspectorItem)

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

        // Wire up source control view
        bottomPanelVC.sourceControlView.setProjectRoot(project.rootURL)
        bottomPanelVC.sourceControlView.delegate = self
        bottomPanelVC.onSourceControlShown = { [weak self] in
            guard let self = self else { return }
            self.bottomPanelVC.sourceControlView.refresh(gitStatus: self.project.gitStatus)
        }

        // Wire up problems view
        bottomPanelVC.problemsView.setProjectRoot(project.rootURL)
        bottomPanelVC.problemsView.delegate = self

        // Feed LSP diagnostics into the problems panel
        project.lspClient.onDiagnostics = { [weak self] url, diagnostics in
            guard let self = self else { return }
            self.bottomPanelVC.problemsView.updateDiagnostics(url: url, diagnostics: diagnostics)
            // Also forward to editor for inline rendering
            self.editorContainerVC.handleDiagnostics(url: url, diagnostics: diagnostics)
        }
    }

    func editorAreaDidUpdate() {
        editorContainerVC.refreshEditor()
        inspectorVC.updateFileInfo(document: project.tabManager.currentDocument)
    }

    func syncDocumentContent() {
        editorContainerVC.syncDocumentContent()
    }

    func saveCurrentViewportState() {
        editorContainerVC.saveCurrentViewportState()
    }

    func saveNavigatorState() {
        navigatorVC.saveExpandedState()
    }

    func scrollToLine(_ line: Int, column: Int, selectLength: Int = 0) {
        editorContainerVC.scrollToLine(line, column: column, selectLength: selectLength)
    }

    // MARK: - Focus Editor (Escape)

    func focusEditor() {
        // Collapse bottom panel if it's open
        if splitViewItems.count > 1 && !splitViewItems[1].isCollapsed {
            splitViewItems[1].animator().isCollapsed = true
        }

        // Focus the text view in the editor
        editorContainerVC.focusEditor()
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

    @objc override func toggleInspector(_ sender: Any?) {
        guard let horizontalSplit = splitViewItems.first?.viewController as? NSSplitViewController,
              horizontalSplit.splitViewItems.count > 2 else { return }
        let inspectorItem = horizontalSplit.splitViewItems[2]
        inspectorItem.animator().isCollapsed = !inspectorItem.isCollapsed
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

    func showProblems() {
        showBottomPanel()
        bottomPanelVC.showProblems()
    }

    /// Regex matching Swift/clang compiler output: /path/file.swift:42:10: error: message
    private static let buildErrorPattern = try! NSRegularExpression(
        pattern: #"^(/[^:]+):(\d+):(\d+):\s*(error|warning):\s*(.+)$"#,
        options: .anchorsMatchLines
    )

    func clearBuildDiagnostics() {
        bottomPanelVC.problemsView.clearBuildDiagnostics()
    }

    func parseBuildOutput(_ text: String) {
        let nsText = text as NSString
        let matches = MainSplitViewController.buildErrorPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches {
            guard match.numberOfRanges >= 6 else { continue }
            let path = nsText.substring(with: match.range(at: 1))
            let line = Int(nsText.substring(with: match.range(at: 2))) ?? 1
            let col = Int(nsText.substring(with: match.range(at: 3))) ?? 1
            let kind = nsText.substring(with: match.range(at: 4))
            let message = nsText.substring(with: match.range(at: 5))

            let severity: ProblemsView.Problem.Severity = kind == "error" ? .error : .warning
            let url = URL(fileURLWithPath: path)
            bottomPanelVC.problemsView.addBuildDiagnostic(
                url: url, line: line - 1, column: col - 1,
                message: message, severity: severity,
            )
        }
    }

    // MARK: - Find in Project (⌘⇧F)

    @objc func findInProject(_ sender: Any?) {
        showBottomPanel()
        bottomPanelVC.searchResultsView.setProjectRoot(project.rootURL)
        bottomPanelVC.searchResultsView.delegate = self
        bottomPanelVC.showSearch()
    }

    // MARK: - Source Control

    @objc func showSourceControlAction(_ sender: Any?) {
        showSourceControl()
    }

    func showSourceControl() {
        showBottomPanel()
        bottomPanelVC.sourceControlView.refresh(gitStatus: project.gitStatus)
        bottomPanelVC.showSourceControl()
    }

    @objc func showBottomTab1(_ sender: Any?) { showBottomPanel(); bottomPanelVC.showPanelByIndex(0) }
    @objc func showBottomTab2(_ sender: Any?) { showBottomPanel(); bottomPanelVC.showPanelByIndex(1) }
    @objc func showBottomTab3(_ sender: Any?) { showBottomPanel(); bottomPanelVC.showPanelByIndex(2) }
    @objc func showBottomTab4(_ sender: Any?) { showBottomPanel(); bottomPanelVC.showPanelByIndex(3) }
    @objc func showBottomTab5(_ sender: Any?) { showBottomPanel(); bottomPanelVC.showPanelByIndex(4) }
    @objc func showBottomTab6(_ sender: Any?) {
        showBottomPanel()
        bottomPanelVC.sourceControlView.refresh(gitStatus: project.gitStatus)
        bottomPanelVC.showPanelByIndex(5)
    }
}

extension MainSplitViewController: SearchResultsViewDelegate {
    func searchResultsView(_ view: SearchResultsView, didSelectResult result: SearchResult, matchLength: Int) {
        windowController?.openFile(result.url, atLine: result.line - 1, column: result.column - 1, selectLength: matchLength)
    }
}

extension MainSplitViewController: BuildLogViewDelegate {
    func buildLogView(_ view: BuildLogView, didClickFileReference url: URL, line: Int, column: Int) {
        windowController?.openFile(url, atLine: line, column: column)
    }
}

extension MainSplitViewController: SourceControlViewDelegate {
    func sourceControlView(_ view: SourceControlView, didSelectFile url: URL) {
        windowController?.openFile(url)
    }
}

extension MainSplitViewController: ProblemsViewDelegate {
    func problemsView(_ view: ProblemsView, didSelectProblem url: URL, line: Int, column: Int) {
        windowController?.openFile(url, atLine: line, column: column)
    }
}
