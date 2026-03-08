import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple instances — activate existing one if found
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        let others = runningApps.filter { $0 != NSRunningApplication.current }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        setupMainMenu()

        // Determine project root from command line args or default
        let projectURL: URL
        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            projectURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        let project = ForgeProject(rootURL: projectURL)
        windowController = MainWindowController(project: project)
        windowController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Forge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Forge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        let openQuickly = NSMenuItem(title: "Open Quickly…", action: #selector(MainWindowController.showOpenQuickly(_:)), keyEquivalent: "O")
        openQuickly.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openQuickly)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(MainWindowController.closeCurrentTab(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        let findItem = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)

        editMenu.addItem(.separator())

        let findInProject = NSMenuItem(title: "Find in Project…", action: #selector(MainSplitViewController.findInProject(_:)), keyEquivalent: "F")
        findInProject.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findInProject)

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Toggle Comment", action: #selector(EditorContainerViewController.toggleComment(_:)), keyEquivalent: "/")

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let toggleNav = NSMenuItem(title: "Toggle Navigator", action: #selector(MainSplitViewController.toggleNavigator(_:)), keyEquivalent: "0")
        viewMenu.addItem(toggleNav)

        let toggleBottom = NSMenuItem(title: "Toggle Bottom Panel", action: #selector(MainSplitViewController.toggleBottomPanel(_:)), keyEquivalent: "Y")
        toggleBottom.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleBottom)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Navigate menu
        let navMenuItem = NSMenuItem()
        let navMenu = NSMenu(title: "Navigate")

        let prevTab = NSMenuItem(title: "Previous Tab", action: #selector(MainWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(prevTab)

        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(MainWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(nextTab)

        let reopenTab = NSMenuItem(title: "Reopen Closed Tab", action: #selector(MainWindowController.reopenLastTab(_:)), keyEquivalent: "T")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(reopenTab)

        let revealInNav = NSMenuItem(title: "Reveal in Navigator", action: #selector(MainSplitViewController.revealInNavigator(_:)), keyEquivalent: "J")
        revealInNav.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(revealInNav)

        navMenu.addItem(.separator())

        let goBack = NSMenuItem(title: "Go Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        goBack.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(goBack)

        let goForward = NSMenuItem(title: "Go Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        goForward.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(goForward)

        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // Product menu (Build)
        let productMenuItem = NSMenuItem()
        let productMenu = NSMenu(title: "Product")

        productMenu.addItem(withTitle: "Build", action: #selector(MainWindowController.buildProject(_:)), keyEquivalent: "b")

        let stopItem = NSMenuItem(title: "Stop", action: #selector(MainWindowController.stopBuild(_:)), keyEquivalent: ".")
        productMenu.addItem(stopItem)

        productMenuItem.submenu = productMenu
        mainMenu.addItem(productMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Actions

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.sourceCode, .plainText, .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.hasDirectoryPath {
            let project = ForgeProject(rootURL: url)
            let wc = MainWindowController(project: project)
            wc.showWindow(nil)
        } else {
            windowController?.openFile(url)
        }
    }

    @objc private func saveDocument(_ sender: Any?) {
        windowController?.saveCurrentDocument()
    }
}
