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
        window.minSize = NSSize(width: 600, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)

        splitViewController = MainSplitViewController(project: project, windowController: self)
        window.contentViewController = splitViewController

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1100)
        let windowWidth = max(1440, screenFrame.width * 0.80)
        let windowHeight = max(900, screenFrame.height * 0.80)
        let origin = NSPoint(
            x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
            y: screenFrame.origin.y + (screenFrame.height - windowHeight) / 2,
        )
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: windowWidth, height: windowHeight), display: true)

        openInitialFile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - File operations

    func openFile(_ url: URL) {
        let doc = project.document(for: url)
        project.tabManager.openOrFocus(document: doc)
        project.navigationHistory.push(url: url)
        splitViewController.editorAreaDidUpdate()
    }

    /// Open a file and scroll to a specific line/column (0-based, LSP convention)
    func openFile(_ url: URL, atLine line: Int, column: Int) {
        openFile(url)
        splitViewController.scrollToLine(line, column: column)
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

    // MARK: - Build

    @objc func buildProject(_ sender: Any?) {
        splitViewController.showBottomPanel()
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
