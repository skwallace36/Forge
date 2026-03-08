import AppKit

class MainWindowController: NSWindowController, OpenQuicklyDelegate {

    let project: ForgeProject
    private var splitViewController: MainSplitViewController!
    private var openQuicklyController: OpenQuicklyWindowController?

    init(project: ForgeProject) {
        self.project = project

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Forge — \(project.displayName)"
        window.setFrameAutosaveName("ForgeMainWindow")
        window.minSize = NSSize(width: 600, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)

        splitViewController = MainSplitViewController(project: project, windowController: self)
        window.contentViewController = splitViewController
        window.center()

        // Open first Swift file if project has one
        openInitialFile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - File operations

    func openFile(_ url: URL) {
        let doc = project.document(for: url)
        project.tabManager.openOrFocus(document: doc)
        splitViewController.editorAreaDidUpdate()
    }

    func saveCurrentDocument() {
        guard let doc = project.tabManager.currentDocument else { return }
        try? doc.save()
        splitViewController.editorAreaDidUpdate()
    }

    // MARK: - Tab actions

    @objc func closeCurrentTab(_ sender: Any?) {
        project.tabManager.closeCurrent()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        project.tabManager.selectPrevious()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func selectNextTab(_ sender: Any?) {
        project.tabManager.selectNext()
        splitViewController.editorAreaDidUpdate()
    }

    @objc func reopenLastTab(_ sender: Any?) {
        project.tabManager.reopenLast()
        splitViewController.editorAreaDidUpdate()
    }

    // MARK: - Open Quickly

    @objc func showOpenQuickly(_ sender: Any?) {
        guard let win = window else { return }
        if openQuicklyController == nil {
            openQuicklyController = OpenQuicklyWindowController(projectRoot: project.rootURL)
            openQuicklyController?.delegate = self
        }
        openQuicklyController?.showInWindow(win)
    }

    func openQuickly(_ controller: OpenQuicklyWindowController, didSelectURL url: URL) {
        openFile(url)
    }

    // MARK: - Initial file

    private func openInitialFile() {
        // Find the first .swift file in the project root
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: project.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            if url.pathExtension == "swift" && !url.lastPathComponent.hasPrefix(".") {
                openFile(url)
                return
            }
        }
    }
}
