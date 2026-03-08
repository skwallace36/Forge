import AppKit

/// Container for the jump bar + tab bar + editor view + status bar. Lives in the center pane.
class EditorContainerViewController: NSViewController, TabBarDelegate {

    let project: ForgeProject
    private let jumpBar = JumpBar()
    private let tabBar = TabBar()
    private let editor = ForgeEditorManager()
    private let statusBar = StatusBar()
    private let placeholderLabel = NSTextField(labelWithString: "Open a file to start editing")

    init(project: ForgeProject) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView()

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

        // Placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 16, weight: .light)
        placeholderLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        placeholderLabel.alignment = .center
        container.addSubview(placeholderLabel)

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

            // Scroll view: to the right of gutter, between tab bar and status bar
            sv.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: editor.gutterView.trailingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
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
        editor.onCursorChange = { [weak self] line, column, totalLines in
            guard let self = self else { return }
            let ext = self.project.tabManager.currentDocument?.fileExtension
            self.statusBar.update(line: line, column: column, totalLines: totalLines, fileExtension: ext)
        }

        // Wire up jump-to-definition
        editor.onJumpToDefinition = { [weak self] url, line, column in
            self?.windowController?.openFile(url, atLine: line, column: column)
        }

        refreshEditor()
    }

    func refreshEditor() {
        let tabManager = project.tabManager
        tabBar.update(tabs: tabManager.tabs, selectedIndex: tabManager.selectedIndex)

        if let doc = tabManager.currentDocument {
            editor.scrollView.isHidden = false
            editor.gutterView.isHidden = false
            placeholderLabel.isHidden = true
            editor.displayDocument(doc)
            jumpBar.update(fileURL: doc.url, projectRoot: project.rootURL)
            statusBar.update(line: 1, column: 1, totalLines: 1, fileExtension: doc.fileExtension)
        } else {
            editor.scrollView.isHidden = true
            editor.gutterView.isHidden = true
            placeholderLabel.isHidden = false
            jumpBar.update(fileURL: nil, projectRoot: nil)
        }
    }

    // MARK: - TabBarDelegate

    func tabBar(_ tabBar: TabBar, didSelectTabAt index: Int) {
        project.tabManager.select(at: index)
        refreshEditor()
    }

    func tabBar(_ tabBar: TabBar, didCloseTabAt index: Int) {
        project.tabManager.close(at: index)
        refreshEditor()
    }

    // MARK: - Toggle Comment (forwarded to editor manager)

    @objc func toggleComment(_ sender: Any?) {
        editor.toggleComment(sender)
    }

    // MARK: - Navigation

    func scrollToLine(_ line: Int, column: Int) {
        editor.scrollToLine(line, column: column)
    }
}
