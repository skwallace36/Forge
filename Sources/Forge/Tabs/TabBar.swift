import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBar, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBar, didCloseTabAt index: Int)
    func tabBar(_ tabBar: TabBar, didMoveTabFrom sourceIndex: Int, to destIndex: Int)
}

/// Custom tab bar view — single row of tabs above the editor.
class TabBar: NSView {

    weak var delegate: TabBarDelegate?
    private var tabButtons: [TabButton] = []
    private var selectedIndex: Int = -1

    private let tabHeight: CGFloat = 30
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

    func update(tabs: [TabManager.Tab], selectedIndex: Int) {
        self.selectedIndex = selectedIndex

        // Remove old buttons
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()

        var xOffset: CGFloat = 0

        for (index, tab) in tabs.enumerated() {
            let button = TabButton(
                frame: NSRect(x: xOffset, y: 0, width: tabWidth, height: tabHeight)
            )
            button.title = tab.title
            button.isSelected = (index == selectedIndex)
            button.isModified = tab.isModified
            button.index = index
            button.target = self
            button.selectAction = #selector(tabClicked(_:))
            button.closeAction = #selector(tabCloseClicked(_:))
            addSubview(button)
            tabButtons.append(button)
            xOffset += tabWidth
        }

        needsDisplay = true
    }

    private let tabWidth: CGFloat = 150

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

        // Drag loop
        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            if nextEvent.type == .leftMouseUp { break }

            let currentLocation = convert(nextEvent.locationInWindow, from: nil)
            let deltaX = currentLocation.x - startLocation.x

            // Calculate which tab position the drag is over
            let dragCenter = CGFloat(originalIndex) * tabWidth + tabWidth / 2 + deltaX
            var targetIndex = Int(dragCenter / tabWidth)
            targetIndex = max(0, min(targetIndex, tabButtons.count - 1))

            if targetIndex != currentIndex {
                // Swap buttons visually
                let sourceButton = tabButtons.remove(at: currentIndex)
                tabButtons.insert(sourceButton, at: targetIndex)

                // Update indices
                for (i, btn) in tabButtons.enumerated() {
                    btn.index = i
                    btn.frame.origin.x = CGFloat(i) * tabWidth
                }

                delegate?.tabBar(self, didMoveTabFrom: currentIndex, to: targetIndex)
                currentIndex = targetIndex
            }

            // Move the dragged button to follow the mouse
            button.frame.origin.x = max(0, currentLocation.x - tabWidth / 2)
        }

        // Snap back to grid position
        for (i, btn) in tabButtons.enumerated() {
            btn.frame.origin.x = CGFloat(i) * tabWidth
        }
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
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isModified: Bool = false { didSet { needsDisplay = true } }
    var index: Int = 0

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

        // Title
        let displayTitle = (isModified ? "● " : "") + title
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? selectedTextColor : textColor,
        ]
        let titleStr = displayTitle as NSString
        let size = titleStr.size(withAttributes: attrs)
        let maxWidth = bounds.width - 30
        let drawRect = NSRect(
            x: 10,
            y: (bounds.height - size.height) / 2,
            width: min(size.width, maxWidth),
            height: size.height
        )
        titleStr.draw(with: drawRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)

        // Close button (×) on hover or selected
        if isHovered || isSelected {
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
    }
}
