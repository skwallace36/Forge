import Foundation

/// Tracks back/forward navigation history for ⌃⌘←/→.
class NavigationHistory {

    struct Entry {
        let url: URL
        let line: Int
        let character: Int
    }

    private var backStack: [Entry] = []
    private var forwardStack: [Entry] = []
    private var current: Entry?

    /// Record a navigation to a new location. Clears forward stack.
    func push(url: URL, line: Int = 0, character: Int = 0) {
        if let current = current {
            backStack.append(current)
        }
        current = Entry(url: url, line: line, character: character)
        forwardStack.removeAll()
    }

    /// Go back. Returns the entry to navigate to, or nil if at start.
    func goBack() -> Entry? {
        guard let prev = backStack.popLast() else { return nil }
        if let current = current {
            forwardStack.append(current)
        }
        current = prev
        return prev
    }

    /// Go forward. Returns the entry to navigate to, or nil if at end.
    func goForward() -> Entry? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current = current {
            backStack.append(current)
        }
        current = next
        return next
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
}
