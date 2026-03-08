import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowControllers: [MainWindowController] = []
    private var preferencesWindow: PreferencesWindowController?

    /// The frontmost window controller, for menu actions
    private var windowController: MainWindowController? {
        if let keyWindow = NSApp.keyWindow {
            return windowControllers.first { $0.window === keyWindow }
        }
        return windowControllers.first
    }

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
        let wc = MainWindowController(project: project)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Handle files opened from Finder (double-click, drag onto dock icon, etc.)
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if url.hasDirectoryPath {
                // Open as a new project
                let project = ForgeProject(rootURL: url)
                let wc = MainWindowController(project: project)
                windowControllers.append(wc)
                wc.showWindow(nil)
            } else {
                // Open file in existing window, or create one if needed
                if let wc = windowController {
                    wc.openFile(url)
                } else {
                    let dir = url.deletingLastPathComponent()
                    let project = ForgeProject(rootURL: dir)
                    let wc = MainWindowController(project: project)
                    windowControllers.append(wc)
                    wc.showWindow(nil)
                    wc.openFile(url)
                }
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    /// Called by MainWindowController when its window closes
    func windowControllerDidClose(_ wc: MainWindowController) {
        windowControllers.removeAll { $0 === wc }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Auto-save all modified documents when switching away from the app
        for wc in windowControllers {
            wc.autoSaveAll()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Check for external file changes when returning to the app
        for wc in windowControllers {
            wc.checkForExternalChanges()
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Forge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Forge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New File…", action: #selector(newFile(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        let openQuickly = NSMenuItem(title: "Open Quickly…", action: #selector(MainWindowController.showOpenQuickly(_:)), keyEquivalent: "O")
        openQuickly.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openQuickly)

        // Open Recent submenu
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.performSelector(onMainThread: NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu", waitUntilDone: false)
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")

        let saveAll = NSMenuItem(title: "Save All", action: #selector(saveAllDocuments(_:)), keyEquivalent: "s")
        saveAll.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(saveAll)

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

        let findReplaceItem = NSMenuItem(title: "Find and Replace…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findReplaceItem.keyEquivalentModifierMask = [.command, .option]
        findReplaceItem.tag = Int(NSTextFinder.Action.showReplaceInterface.rawValue)
        editMenu.addItem(findReplaceItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNextItem.tag = Int(NSTextFinder.Action.nextMatch.rawValue)
        editMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.tag = Int(NSTextFinder.Action.previousMatch.rawValue)
        editMenu.addItem(findPrevItem)

        let useSelectionItem = NSMenuItem(title: "Use Selection for Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "e")
        useSelectionItem.tag = Int(NSTextFinder.Action.setSearchString.rawValue)
        editMenu.addItem(useSelectionItem)

        editMenu.addItem(.separator())

        let findInProject = NSMenuItem(title: "Find in Project…", action: #selector(MainSplitViewController.findInProject(_:)), keyEquivalent: "F")
        findInProject.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findInProject)

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Toggle Comment", action: #selector(EditorContainerViewController.toggleComment(_:)), keyEquivalent: "/")

        let reindentItem = NSMenuItem(title: "Re-Indent", action: #selector(EditorContainerViewController.reindentSelection(_:)), keyEquivalent: "i")
        reindentItem.keyEquivalentModifierMask = [.control]
        editMenu.addItem(reindentItem)

        editMenu.addItem(.separator())

        let goToLineItem = NSMenuItem(title: "Go to Line…", action: #selector(EditorContainerViewController.goToLine(_:)), keyEquivalent: "l")
        editMenu.addItem(goToLineItem)

        let renameItem = NSMenuItem(title: "Edit All in Scope", action: #selector(EditorContainerViewController.renameSymbol(_:)), keyEquivalent: "e")
        renameItem.keyEquivalentModifierMask = [.command, .control]
        editMenu.addItem(renameItem)

        editMenu.addItem(.separator())

        let sortLinesItem = NSMenuItem(title: "Sort Lines", action: #selector(EditorContainerViewController.sortLines(_:)), keyEquivalent: "")
        editMenu.addItem(sortLinesItem)

        let removeDupsItem = NSMenuItem(title: "Remove Duplicate Lines", action: #selector(EditorContainerViewController.removeDuplicateLines(_:)), keyEquivalent: "")
        editMenu.addItem(removeDupsItem)

        editMenu.addItem(.separator())

        // Transform submenu
        let transformMenu = NSMenu(title: "Transform")
        let uppercaseItem = NSMenuItem(title: "Make Uppercase", action: #selector(EditorContainerViewController.transformToUppercase(_:)), keyEquivalent: "u")
        uppercaseItem.keyEquivalentModifierMask = [.control, .shift]
        transformMenu.addItem(uppercaseItem)

        let lowercaseItem = NSMenuItem(title: "Make Lowercase", action: #selector(EditorContainerViewController.transformToLowercase(_:)), keyEquivalent: "u")
        lowercaseItem.keyEquivalentModifierMask = [.control]
        transformMenu.addItem(lowercaseItem)

        let titleCaseItem = NSMenuItem(title: "Title Case", action: #selector(EditorContainerViewController.transformToTitleCase(_:)), keyEquivalent: "")
        transformMenu.addItem(titleCaseItem)

        let transformItem = NSMenuItem(title: "Transform", action: nil, keyEquivalent: "")
        transformItem.submenu = transformMenu
        editMenu.addItem(transformItem)

        editMenu.addItem(.separator())

        let formatItem = NSMenuItem(title: "Format Document", action: #selector(EditorContainerViewController.formatDocument(_:)), keyEquivalent: "i")
        formatItem.keyEquivalentModifierMask = [.control, .shift]
        editMenu.addItem(formatItem)

        editMenu.addItem(.separator())

        let moveLineUpItem = NSMenuItem(title: "Move Line Up", action: #selector(EditorContainerViewController.moveLineUp(_:)), keyEquivalent: "[")
        moveLineUpItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(moveLineUpItem)

        let moveLineDownItem = NSMenuItem(title: "Move Line Down", action: #selector(EditorContainerViewController.moveLineDown(_:)), keyEquivalent: "]")
        moveLineDownItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(moveLineDownItem)

        let duplicateLineItem = NSMenuItem(title: "Duplicate Line", action: #selector(EditorContainerViewController.duplicateLine(_:)), keyEquivalent: "D")
        duplicateLineItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(duplicateLineItem)

        let deleteLineItem = NSMenuItem(title: "Delete Line", action: #selector(EditorContainerViewController.deleteLine(_:)), keyEquivalent: "K")
        deleteLineItem.keyEquivalentModifierMask = [.control, .shift]
        editMenu.addItem(deleteLineItem)

        let joinLinesItem = NSMenuItem(title: "Join Lines", action: #selector(EditorContainerViewController.joinLines(_:)), keyEquivalent: "j")
        joinLinesItem.keyEquivalentModifierMask = [.control]
        editMenu.addItem(joinLinesItem)

        editMenu.addItem(.separator())

        let selectNextItem = NSMenuItem(title: "Select Next Occurrence", action: #selector(EditorContainerViewController.selectNextOccurrence(_:)), keyEquivalent: "d")
        editMenu.addItem(selectNextItem)

        let sendToClaudeItem = NSMenuItem(title: "Send to Claude", action: #selector(EditorContainerViewController.sendToClaude(_:)), keyEquivalent: "c")
        sendToClaudeItem.keyEquivalentModifierMask = [.control, .shift]
        editMenu.addItem(sendToClaudeItem)

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

        let showSC = NSMenuItem(title: "Source Control", action: #selector(MainSplitViewController.showSourceControlAction(_:)), keyEquivalent: "2")
        showSC.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(showSC)

        viewMenu.addItem(.separator())

        let toggleMinimap = NSMenuItem(title: "Toggle Minimap", action: #selector(EditorContainerViewController.toggleMinimap(_:)), keyEquivalent: "M")
        toggleMinimap.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleMinimap)

        let toggleWordWrap = NSMenuItem(title: "Toggle Word Wrap", action: #selector(EditorContainerViewController.toggleWordWrap(_:)), keyEquivalent: "L")
        toggleWordWrap.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleWordWrap)

        let toggleInvisibles = NSMenuItem(title: "Toggle Invisible Characters", action: #selector(EditorContainerViewController.toggleInvisibles(_:)), keyEquivalent: "i")
        toggleInvisibles.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleInvisibles)

        viewMenu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(EditorContainerViewController.increaseFontSize(_:)), keyEquivalent: "+")
        viewMenu.addItem(zoomIn)

        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(EditorContainerViewController.decreaseFontSize(_:)), keyEquivalent: "-")
        viewMenu.addItem(zoomOut)

        let resetZoom = NSMenuItem(title: "Reset Zoom", action: #selector(EditorContainerViewController.resetFontSize(_:)), keyEquivalent: "0")
        resetZoom.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(resetZoom)

        viewMenu.addItem(.separator())

        let foldItem = NSMenuItem(title: "Fold", action: #selector(EditorContainerViewController.foldAtCursor(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        foldItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(foldItem)

        let unfoldItem = NSMenuItem(title: "Unfold", action: #selector(EditorContainerViewController.unfoldAtCursor(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        unfoldItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(unfoldItem)

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

        let switchRecent = NSMenuItem(title: "Switch to Recent Tab", action: #selector(MainWindowController.switchToMostRecentTab(_:)), keyEquivalent: "\t")
        switchRecent.keyEquivalentModifierMask = [.control]
        navMenu.addItem(switchRecent)

        navMenu.addItem(.separator())

        // ⌘1-9 for tab switching
        for i in 1...9 {
            let tabItem = NSMenuItem(title: "Select Tab \(i)", action: #selector(MainWindowController.selectTabByNumber(_:)), keyEquivalent: "\(i)")
            tabItem.tag = i
            navMenu.addItem(tabItem)
        }

        navMenu.addItem(.separator())

        let focusEditor = NSMenuItem(title: "Focus Editor", action: #selector(MainWindowController.focusEditor(_:)), keyEquivalent: String(Character(UnicodeScalar(27))))
        focusEditor.keyEquivalentModifierMask = []
        navMenu.addItem(focusEditor)

        navMenu.addItem(.separator())

        let goBack = NSMenuItem(title: "Go Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        goBack.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(goBack)

        let goForward = NSMenuItem(title: "Go Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        goForward.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(goForward)

        navMenu.addItem(.separator())

        let goToLine = NSMenuItem(title: "Go to Line…", action: #selector(EditorContainerViewController.goToLine(_:)), keyEquivalent: "l")
        navMenu.addItem(goToLine)

        let findRefs = NSMenuItem(title: "Find All References", action: #selector(EditorContainerViewController.findReferences(_:)), keyEquivalent: "")
        navMenu.addItem(findRefs)

        let docSymbols = NSMenuItem(title: "Document Symbols", action: #selector(EditorContainerViewController.showDocumentSymbols(_:)), keyEquivalent: "6")
        docSymbols.keyEquivalentModifierMask = [.control]
        navMenu.addItem(docSymbols)

        let nextIssue = NSMenuItem(title: "Jump to Next Issue", action: #selector(EditorContainerViewController.jumpToNextIssue(_:)), keyEquivalent: "'")
        nextIssue.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(nextIssue)

        let prevIssue = NSMenuItem(title: "Jump to Previous Issue", action: #selector(EditorContainerViewController.jumpToPreviousIssue(_:)), keyEquivalent: "\"")
        prevIssue.keyEquivalentModifierMask = [.command, .control]
        navMenu.addItem(prevIssue)

        navMenuItem.submenu = navMenu
        mainMenu.addItem(navMenuItem)

        // Product menu (Build)
        let productMenuItem = NSMenuItem()
        let productMenu = NSMenu(title: "Product")

        productMenu.addItem(withTitle: "Build", action: #selector(MainWindowController.buildProject(_:)), keyEquivalent: "b")
        productMenu.addItem(withTitle: "Run", action: #selector(MainWindowController.runProject(_:)), keyEquivalent: "r")

        let cleanItem = NSMenuItem(title: "Clean Build", action: #selector(MainWindowController.cleanBuild(_:)), keyEquivalent: "K")
        cleanItem.keyEquivalentModifierMask = [.command, .shift]
        productMenu.addItem(cleanItem)

        productMenu.addItem(.separator())

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

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts(_:)), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Actions

    @objc private func newFile(_ sender: Any?) {
        guard let wc = windowController else { return }

        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Enter the file name:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = "filename.swift"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let fileURL = wc.project.rootURL.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        wc.openFile(fileURL)
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        for url in panel.urls {
            if url.hasDirectoryPath {
                let project = ForgeProject(rootURL: url)
                let wc = MainWindowController(project: project)
                windowControllers.append(wc)
                wc.showWindow(nil)
            } else {
                windowController?.openFile(url)
            }
        }
    }

    @objc private func saveDocument(_ sender: Any?) {
        windowController?.saveCurrentDocument()
    }

    @objc private func saveAllDocuments(_ sender: Any?) {
        windowController?.saveAllDocuments()
    }

    @objc private func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Forge Keyboard Shortcuts"
        alert.informativeText = """
        File
          ⌘N   New File          ⌘O   Open File
          ⌘S   Save              ⌘⌥S  Save All
          ⌘W   Close Tab

        Edit
          ⌘F   Find              ⌘⌥F  Find & Replace
          ⌘⇧F  Find in Project   ⌘L   Go to Line
          ⌘/   Toggle Comment    ⌃I   Re-Indent
          ⌘D   Select Next       ⌘⇧L  Select All Occurrences
          ⌘⇧D  Duplicate Line    ⌃⇧K  Delete Line
          ⌘⌥[  Move Line Up      ⌘⌥]  Move Line Down
          ⌃J   Join Lines        ⌃⇧I  Format Document

        Navigation
          ⇧⌘O  Open Quickly      ⌘1-9 Select Tab
          ⌘⇧[  Previous Tab      ⌘⇧]  Next Tab
          ⌘⇧T  Reopen Tab        ⌘⇧J  Reveal in Navigator
          ⌃⌘←  Go Back           ⌃⌘→  Go Forward
          ⌃6   Document Symbols  Esc   Focus Editor

        View
          ⌘0   Toggle Navigator   ⌘⇧Y  Toggle Bottom Panel
          ⌃⌘M  Toggle Minimap     ⌘⌥L  Toggle Word Wrap
          ⌘+   Zoom In            ⌘-   Zoom Out
          ⌘⌥←  Fold               ⌘⌥→  Unfold

        Build
          ⌘B   Build              ⌘R   Run
          ⌘.   Stop               ⌘⇧K  Clean Build
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
