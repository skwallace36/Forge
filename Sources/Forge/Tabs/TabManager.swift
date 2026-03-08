import Foundation

class TabManager {

    struct Tab {
        let document: ForgeDocument
        var isPinned: Bool = false
        /// Preview tabs are shown in italics and get replaced by the next preview
        var isPreview: Bool = false

        var title: String { document.fileName }
        var isModified: Bool { document.isModified }
        var url: URL { document.url }
    }

    /// Returns display title for a tab, adding parent directory if another tab has the same filename
    func displayTitle(for index: Int) -> String {
        guard index >= 0 && index < tabs.count else { return "" }
        let tab = tabs[index]
        let name = tab.title
        let hasDuplicate = tabs.enumerated().contains { i, other in
            i != index && other.title == name
        }
        if hasDuplicate {
            let parent = tab.url.deletingLastPathComponent().lastPathComponent
            return "\(name) — \(parent)"
        }
        return name
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex: Int = -1 {
        didSet {
            if oldValue != selectedIndex && oldValue >= 0 && oldValue < tabs.count {
                previousSelectedURL = tabs[oldValue].url
            }
        }
    }
    /// Track MRU by URL so it survives tab close/reorder
    private var previousSelectedURL: URL?
    private var recentlyClosedURLs: [URL] = []

    var currentTab: Tab? {
        guard selectedIndex >= 0 && selectedIndex < tabs.count else { return nil }
        return tabs[selectedIndex]
    }

    var currentDocument: ForgeDocument? {
        currentTab?.document
    }

    /// Open a document in a new tab or focus existing tab
    func openOrFocus(document: ForgeDocument) {
        if let existingIndex = tabs.firstIndex(where: { $0.url == document.url }) {
            selectedIndex = existingIndex
            // If this was a preview tab, promote it to permanent
            if tabs[existingIndex].isPreview {
                tabs[existingIndex].isPreview = false
            }
        } else {
            let tab = Tab(document: document)
            // Insert after current tab
            let insertIndex = selectedIndex >= 0 ? selectedIndex + 1 : tabs.count
            tabs.insert(tab, at: insertIndex)
            selectedIndex = insertIndex
        }
    }

    /// Open a document as a preview tab — replaces any existing preview tab.
    /// If the document is already open (preview or permanent), just focuses it.
    func openPreview(document: ForgeDocument) {
        // If already open, just select it
        if let existingIndex = tabs.firstIndex(where: { $0.url == document.url }) {
            selectedIndex = existingIndex
            return
        }

        // Replace existing preview tab if any
        if let previewIndex = tabs.firstIndex(where: { $0.isPreview }) {
            let closed = tabs.remove(at: previewIndex)
            onTabClosed?(closed.url)
            if closed.isModified {
                recentlyClosedURLs.append(closed.url)
            }
            // Adjust selected index after removal
            if selectedIndex > previewIndex {
                selectedIndex -= 1
            } else if selectedIndex == previewIndex {
                selectedIndex = max(0, selectedIndex - 1)
            }
        }

        var tab = Tab(document: document)
        tab.isPreview = true
        let insertIndex = selectedIndex >= 0 ? selectedIndex + 1 : tabs.count
        tabs.insert(tab, at: insertIndex)
        selectedIndex = insertIndex
    }

    /// Promote the current preview tab to a permanent tab (e.g., when user edits it)
    func promoteCurrentPreview() {
        guard selectedIndex >= 0 && selectedIndex < tabs.count,
              tabs[selectedIndex].isPreview else { return }
        tabs[selectedIndex].isPreview = false
    }

    func closeCurrent() {
        guard selectedIndex >= 0 && selectedIndex < tabs.count else { return }
        let closed = tabs.remove(at: selectedIndex)
        recentlyClosedURLs.append(closed.url)
        onTabClosed?(closed.url)

        if tabs.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
    }

    func close(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let closed = tabs.remove(at: index)
        recentlyClosedURLs.append(closed.url)
        onTabClosed?(closed.url)

        if tabs.isEmpty {
            selectedIndex = -1
        } else if index <= selectedIndex {
            selectedIndex = max(0, selectedIndex - 1)
        }
    }

    /// Called when a tab is closed so the project can clean up LSP/documents
    var onTabClosed: ((URL) -> Void)?

    func selectPrevious() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex - 1 + tabs.count) % tabs.count
    }

    func selectNext() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex + 1) % tabs.count
    }

    /// Switch to the most recently used tab (Ctrl+Tab)
    func switchToMostRecent() {
        guard tabs.count > 1 else { return }
        if let url = previousSelectedURL,
           let index = tabs.firstIndex(where: { $0.url == url }),
           index != selectedIndex {
            selectedIndex = index
        } else {
            selectPrevious()
        }
    }

    func select(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedIndex = index
    }

    func moveTab(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count,
              destIndex >= 0 && destIndex < tabs.count,
              sourceIndex != destIndex else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destIndex)
        // Adjust selected index
        if selectedIndex == sourceIndex {
            selectedIndex = destIndex
        } else if sourceIndex < selectedIndex && destIndex >= selectedIndex {
            selectedIndex -= 1
        } else if sourceIndex > selectedIndex && destIndex <= selectedIndex {
            selectedIndex += 1
        }
    }

    /// The most recently closed URL (for reopen)
    var lastClosedURL: URL? { recentlyClosedURLs.last }

    func popLastClosedURL() -> URL? {
        recentlyClosedURLs.popLast()
    }

    /// Close all tabs except the one at the given index
    func closeOthers(keepingIndex index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let kept = tabs[index]
        for (i, tab) in tabs.enumerated() where i != index {
            recentlyClosedURLs.append(tab.url)
            onTabClosed?(tab.url)
        }
        tabs = [kept]
        selectedIndex = 0
    }

    /// Close all tabs
    func closeAll() {
        for tab in tabs {
            recentlyClosedURLs.append(tab.url)
            onTabClosed?(tab.url)
        }
        tabs.removeAll()
        selectedIndex = -1
    }

    /// Close all tabs to the right of the given index
    func closeToRight(fromIndex index: Int) {
        guard index >= 0 && index < tabs.count - 1 else { return }
        let removed = tabs[(index + 1)...]
        for tab in removed {
            recentlyClosedURLs.append(tab.url)
            onTabClosed?(tab.url)
        }
        tabs.removeSubrange((index + 1)...)
        if selectedIndex > index {
            selectedIndex = index
        }
    }
}
