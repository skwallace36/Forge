import Foundation

class TabManager {

    struct Tab {
        let document: ForgeDocument
        var isPinned: Bool = false

        var title: String { document.fileName }
        var isModified: Bool { document.isModified }
        var url: URL { document.url }
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex: Int = -1
    private var recentlyClosed: [ForgeDocument] = []

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
        } else {
            let tab = Tab(document: document)
            // Insert after current tab
            let insertIndex = selectedIndex >= 0 ? selectedIndex + 1 : tabs.count
            tabs.insert(tab, at: insertIndex)
            selectedIndex = insertIndex
        }
    }

    func closeCurrent() {
        guard selectedIndex >= 0 && selectedIndex < tabs.count else { return }
        let closed = tabs.remove(at: selectedIndex)
        recentlyClosed.append(closed.document)

        if tabs.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
    }

    func close(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let closed = tabs.remove(at: index)
        recentlyClosed.append(closed.document)

        if tabs.isEmpty {
            selectedIndex = -1
        } else if index <= selectedIndex {
            selectedIndex = max(0, selectedIndex - 1)
        }
    }

    func selectPrevious() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex - 1 + tabs.count) % tabs.count
    }

    func selectNext() {
        guard tabs.count > 1 else { return }
        selectedIndex = (selectedIndex + 1) % tabs.count
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

    func reopenLast() {
        guard let doc = recentlyClosed.popLast() else { return }
        doc.loadFromDisk()
        openOrFocus(document: doc)
    }
}
