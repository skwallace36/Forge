import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBar, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBar, didCloseTabAt index: Int)
    func tabBar(_ tabBar: TabBar, didMoveTabFrom sourceIndex: Int, to destIndex: Int)
    func tabBarDidRequestCloseOthers(_ tabBar: TabBar, keepingIndex index: Int)
    func tabBarDidRequestCloseAll(_ tabBar: TabBar)
    func tabBarDidRequestCloseToRight(_ tabBar: TabBar, fromIndex index: Int)
}

/// Custom tab bar view — single row of tabs above the editor.
class TabBar: NSView {

    weak var delegate: TabBarDelegate?
    private var tabButtons: [TabButton] = []
    private var selectedIndex: Int = -1

    private let tabHeight: CGFloat = 30
    private let maxTabWidth: CGFloat = 180
    private let minTabWidth: CGFloat = 80
    private let backgroundColor = NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    private var currentTabWidth: CGFloat {
        guard !tabButtons.isEmpty else { return maxTabWidth }
        let available = bounds.width
        let idealWidth = available / CGFloat(tabButtons.count)
        return min(maxTabWidth, max(minTabWidth, idealWidth))
    }

    func update(tabs: [TabManager.Tab], selectedIndex: Int) {
        self.selectedIndex = selectedIndex

        // Remove old buttons
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()

        for (index, tab) in tabs.enumerated() {
            let button = TabButton(frame: .zero)
            button.title = tab.title
            button.fileExtension = tab.document.fileExtension
            button.fileURL = tab.url
            button.isSelected = (index == selectedIndex)
            button.isModified = tab.isModified
            button.index = index
            button.target = self
            button.selectAction = #selector(tabClicked(_:))
            button.closeAction = #selector(tabCloseClicked(_:))
            addSubview(button)
            tabButtons.append(button)
        }

        layoutTabs()
        needsDisplay = true
    }

    private func layoutTabs() {
        let tabW = currentTabWidth
        for (i, btn) in tabButtons.enumerated() {
            btn.frame = NSRect(x: CGFloat(i) * tabW, y: 0, width: tabW, height: tabHeight)
        }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    @objc private func tabClicked(_ sender: TabButton) {
        delegate?.tabBar(self, didSelectTabAt: sender.index)
    }

    @objc private func tabCloseClicked(_ sender: TabButton) {
        delegate?.tabBar(self, didCloseTabAt: sender.index)
    }

    /// Called during drag to reorder tabs visually and notify delegate
    func handleDrag(from button: TabButton, event: NSEvent) {
        let startLocation = convert(event.locationInWindow, from: nil)
        let originalIndex = button.index
        var currentIndex = originalIndex
        let tabW = currentTabWidth

        // Drag loop
        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            if nextEvent.type == .leftMouseUp { break }

            let currentLocation = convert(nextEvent.locationInWindow, from: nil)
            let deltaX = currentLocation.x - startLocation.x

            // Calculate which tab position the drag is over
            let dragCenter = CGFloat(originalIndex) * tabW + tabW / 2 + deltaX
            var targetIndex = Int(dragCenter / tabW)
            targetIndex = max(0, min(targetIndex, tabButtons.count - 1))

            if targetIndex != currentIndex {
                let sourceButton = tabButtons.remove(at: currentIndex)
                tabButtons.insert(sourceButton, at: targetIndex)

                for (i, btn) in tabButtons.enumerated() {
                    btn.index = i
                    btn.frame.origin.x = CGFloat(i) * tabW
                }

                delegate?.tabBar(self, didMoveTabFrom: currentIndex, to: targetIndex)
                currentIndex = targetIndex
            }

            // Move the dragged button to follow the mouse
            button.frame.origin.x = max(0, currentLocation.x - tabW / 2)
        }

        // Snap back to grid position
        for (i, btn) in tabButtons.enumerated() {
            btn.frame.origin.x = CGFloat(i) * tabW
        }
    }

    // MARK: - Tab Context Menu

    func showContextMenu(for button: TabButton, event: NSEvent) {
        let menu = NSMenu()
        let index = button.index

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = index
        menu.addItem(closeItem)

        let closeOthersItem = NSMenuItem(title: "Close Others", action: #selector(contextCloseOthers(_:)), keyEquivalent: "")
        closeOthersItem.target = self
        closeOthersItem.tag = index
        closeOthersItem.isEnabled = tabButtons.count > 1
        menu.addItem(closeOthersItem)

        let closeRightItem = NSMenuItem(title: "Close Tabs to the Right", action: #selector(contextCloseRight(_:)), keyEquivalent: "")
        closeRightItem.target = self
        closeRightItem.tag = index
        closeRightItem.isEnabled = index < tabButtons.count - 1
        menu.addItem(closeRightItem)

        let closeAllItem = NSMenuItem(title: "Close All", action: #selector(contextCloseAll(_:)), keyEquivalent: "")
        closeAllItem.target = self
        menu.addItem(closeAllItem)

        menu.addItem(.separator())

        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = button.fileURL
        menu.addItem(copyPathItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = button.fileURL
        menu.addItem(revealItem)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didCloseTabAt: sender.tag)
    }

    @objc private func contextCloseOthers(_ sender: NSMenuItem) {
        delegate?.tabBarDidRequestCloseOthers(self, keepingIndex: sender.tag)
    }

    @objc private func contextCloseRight(_ sender: NSMenuItem) {
        delegate?.tabBarDidRequestCloseToRight(self, fromIndex: sender.tag)
    }

    @objc private func contextCloseAll(_ sender: NSMenuItem) {
        delegate?.tabBarDidRequestCloseAll(self)
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tabHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        // Bottom border
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - TabButton

class TabButton: NSView {

    var title: String = "" { didSet { needsDisplay = true } }
    var fileExtension: String = "" { didSet { needsDisplay = true } }
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isModified: Bool = false { didSet { needsDisplay = true } }
    var index: Int = 0
    var fileURL: URL?

    weak var target: AnyObject?
    var selectAction: Selector?
    var closeAction: Selector?

    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    private let selectedColor = NSColor(red: 0.18, green: 0.19, blue: 0.21, alpha: 1.0)
    private let hoverColor = NSColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1.0)
    private let normalColor = NSColor.clear
    private let textColor = NSColor(white: 0.75, alpha: 1.0)
    private let selectedTextColor = NSColor.white

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        // Check if close button area was clicked (right side)
        if localPoint.x > bounds.width - 24 {
            if let target = target, let action = closeAction {
                _ = target.perform(action, with: self)
            }
            return
        }

        // Select the tab first
        if let target = target, let action = selectAction {
            _ = target.perform(action, with: self)
        }

        // Start drag tracking
        if let tabBar = superview as? TabBar {
            tabBar.handleDrag(from: self, event: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click to close tab
        if event.buttonNumber == 2 {
            if let target = target, let action = closeAction {
                _ = target.perform(action, with: self)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let tabBar = superview as? TabBar else { return }
        tabBar.showContextMenu(for: self, event: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background
        let bgColor: NSColor
        if isSelected {
            bgColor = selectedColor
        } else if isHovered {
            bgColor = hoverColor
        } else {
            bgColor = normalColor
        }
        bgColor.setFill()
        bounds.fill()

        // Right separator
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: bounds.width - 1, y: 4, width: 1, height: bounds.height - 8).fill()

        // File type icon
        let iconStr = fileIcon(for: fileExtension)
        let iconAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: iconColor(for: fileExtension),
        ]
        let iconSize = (iconStr as NSString).size(withAttributes: iconAttrs)
        let iconX: CGFloat = 8
        (iconStr as NSString).draw(
            at: NSPoint(x: iconX, y: (bounds.height - iconSize.height) / 2),
            withAttributes: iconAttrs
        )

        // Title (with modified dot in close button area)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? selectedTextColor : textColor,
        ]
        let titleStr = title as NSString
        let size = titleStr.size(withAttributes: titleAttrs)
        let titleX: CGFloat = iconX + iconSize.width + 4
        let maxWidth = bounds.width - titleX - 26
        let drawRect = NSRect(
            x: titleX,
            y: (bounds.height - size.height) / 2,
            width: min(size.width, maxWidth),
            height: size.height,
        )
        titleStr.draw(with: drawRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: titleAttrs)

        // Close/modified indicator
        if isHovered || isSelected {
            if isModified {
                // Show modified dot that's also clickable to close
                let dotSize: CGFloat = 7
                let dotRect = NSRect(
                    x: bounds.width - dotSize - 10,
                    y: (bounds.height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize,
                )
                NSColor(white: 0.7, alpha: 1.0).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else {
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(white: 0.6, alpha: 1.0),
                ]
                let closeStr = "×" as NSString
                let closeSize = closeStr.size(withAttributes: closeAttrs)
                closeStr.draw(
                    at: NSPoint(
                        x: bounds.width - closeSize.width - 8,
                        y: (bounds.height - closeSize.height) / 2
                    ),
                    withAttributes: closeAttrs
                )
            }
        } else if isModified {
            // When not hovered, show a small subtle dot
            let dotSize: CGFloat = 6
            let dotRect = NSRect(
                x: bounds.width - dotSize - 10,
                y: (bounds.height - dotSize) / 2,
                width: dotSize,
                height: dotSize,
            )
            NSColor(white: 0.45, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    // MARK: - File Icons

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "𝐒"
        case "m", "mm": return "𝐌"
        case "h", "hpp": return "𝐇"
        case "c": return "𝐂"
        case "cpp", "cc", "cxx": return "⊕"
        case "js": return "𝐉"
        case "ts", "tsx": return "𝐓"
        case "py": return "𝐏"
        case "rb": return "◆"
        case "go": return "𝐆"
        case "rs": return "𝐑"
        case "json": return "{}"
        case "yaml", "yml": return "⋮"
        case "xml", "plist": return "⟨⟩"
        case "html", "htm": return "◇"
        case "css", "scss": return "#"
        case "md", "markdown": return "¶"
        case "sh", "bash", "zsh": return "⌘"
        case "toml": return "≡"
        case "txt": return "☰"
        default: return "◻"
        }
    }

    private func iconColor(for ext: String) -> NSColor {
        switch ext.lowercased() {
        case "swift": return NSColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1.0)
        case "m", "mm", "h", "hpp": return NSColor(red: 0.40, green: 0.60, blue: 0.95, alpha: 1.0)
        case "c", "cpp", "cc", "cxx": return NSColor(red: 0.40, green: 0.60, blue: 0.95, alpha: 1.0)
        case "js": return NSColor(red: 0.95, green: 0.85, blue: 0.30, alpha: 1.0)
        case "ts", "tsx": return NSColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1.0)
        case "py": return NSColor(red: 0.30, green: 0.65, blue: 0.40, alpha: 1.0)
        case "go": return NSColor(red: 0.30, green: 0.75, blue: 0.85, alpha: 1.0)
        case "rs": return NSColor(red: 0.85, green: 0.50, blue: 0.30, alpha: 1.0)
        case "json": return NSColor(red: 0.85, green: 0.75, blue: 0.30, alpha: 1.0)
        case "html", "htm", "css", "scss": return NSColor(red: 0.85, green: 0.40, blue: 0.40, alpha: 1.0)
        case "md", "markdown": return NSColor(red: 0.50, green: 0.70, blue: 0.90, alpha: 1.0)
        default: return NSColor(white: 0.55, alpha: 1.0)
        }
    }
}
