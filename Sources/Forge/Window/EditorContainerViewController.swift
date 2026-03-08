import AppKit

/// Container for the tab bar + editor view. Lives in the center pane.
class EditorContainerViewController: NSViewController, TabBarDelegate {

    let project: ForgeProject
    private let tabBar = TabBar()
    private let editorView = ForgeEditorView()
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
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0).cgColor

        // Tab bar
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        container.addSubview(tabBar)

        // Editor
        editorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editorView)

        // Placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 16, weight: .light)
        placeholderLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        placeholderLabel.alignment = .center
        container.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),

            editorView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshEditor()
    }

    func refreshEditor() {
        let tabManager = project.tabManager
        tabBar.update(tabs: tabManager.tabs, selectedIndex: tabManager.selectedIndex)

        if let doc = tabManager.currentDocument {
            editorView.isHidden = false
            placeholderLabel.isHidden = true
            editorView.displayDocument(doc)
        } else {
            editorView.isHidden = true
            placeholderLabel.isHidden = false
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
}
