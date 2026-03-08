import AppKit

/// Tracks clipboard history and provides a selection popup.
class ClipboardHistory {

    static let shared = ClipboardHistory()

    private var entries: [String] = []
    private let maxEntries = 20
    private var lastChangeCount: Int = 0

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Check if the clipboard has new content and add it to history
    func checkForNewContent() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }

        // Don't duplicate if it's the same as the most recent entry
        if entries.first == text { return }

        entries.insert(text, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    /// Returns recent clipboard entries
    var recentEntries: [String] {
        checkForNewContent()
        return entries
    }

    /// Show a popup menu at the given point in the given view with clipboard history
    func showPopup(in view: NSView, at point: NSPoint, onSelect: @escaping (String) -> Void) {
        checkForNewContent()
        guard !entries.isEmpty else { return }

        let menu = NSMenu(title: "Clipboard History")

        for (i, entry) in entries.prefix(15).enumerated() {
            // Truncate long entries for display
            let display = entry.replacingOccurrences(of: "\n", with: "↵ ")
            let truncated = display.count > 80 ? String(display.prefix(77)) + "..." : display
            let item = NSMenuItem(title: truncated, action: #selector(ClipboardHistoryHelper.menuItemSelected(_:)), keyEquivalent: "")
            item.tag = i
            item.target = ClipboardHistoryHelper.shared
            menu.addItem(item)
        }

        ClipboardHistoryHelper.shared.entries = Array(entries.prefix(15))
        ClipboardHistoryHelper.shared.onSelect = onSelect

        menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// Helper class to handle menu item selection (needs to be an NSObject for @objc)
class ClipboardHistoryHelper: NSObject {
    static let shared = ClipboardHistoryHelper()
    var entries: [String] = []
    var onSelect: ((String) -> Void)?

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < entries.count else { return }
        onSelect?(entries[index])
    }
}
