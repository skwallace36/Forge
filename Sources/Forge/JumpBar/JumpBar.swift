import AppKit

/// Breadcrumb path bar above the editor — shows project > folder > file path.
/// Clicking the filename shows document symbols for quick navigation.
class JumpBar: NSView {

    /// Called when user selects a symbol: (line, column) — 0-based
    var onSymbolSelected: ((Int, Int) -> Void)?

    /// Called to fetch document symbols asynchronously
    var onRequestSymbols: ((@escaping ([LSPDocumentSymbol]) -> Void) -> Void)?

    /// Called when user selects a sibling file from breadcrumb popup
    var onFileSelected: ((URL) -> Void)?

    private var fileURL: URL?
    private var projectRoot: URL?
    private var pathComponents: [String] = []
    private var labels: [NSTextField] = []
    private var separators: [NSTextField] = []

    let barHeight: CGFloat = 24
    private let backgroundColor = NSColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0)
    private let textColor = NSColor(white: 0.60, alpha: 1.0)
    private let activeTextColor = NSColor(white: 0.85, alpha: 1.0)
    private let separatorColor = NSColor(white: 0.35, alpha: 1.0)

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

    func update(fileURL: URL?, projectRoot: URL?) {
        self.fileURL = fileURL
        self.projectRoot = projectRoot

        // Clear old views
        labels.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        separators.removeAll()

        guard let fileURL = fileURL else {
            pathComponents = []
            return
        }

        // Build path components relative to project root
        if let root = projectRoot {
            let rootPath = root.path
            let filePath = fileURL.path
            if filePath.hasPrefix(rootPath) {
                let relativePath = String(filePath.dropFirst(rootPath.count + 1))
                pathComponents = [root.lastPathComponent] + relativePath.split(separator: "/").map(String.init)
            } else {
                pathComponents = Array(fileURL.pathComponents.suffix(3))
            }
        } else {
            pathComponents = [fileURL.lastPathComponent]
        }

        // Build UI
        var xOffset: CGFloat = 10

        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1

            // Separator (except before first)
            if index > 0 {
                let sep = makeLabel("›", color: separatorColor, bold: false)
                sep.frame.origin = NSPoint(x: xOffset, y: (barHeight - sep.frame.height) / 2)
                addSubview(sep)
                separators.append(sep)
                xOffset += sep.frame.width + 4
            }

            let label = makeLabel(component, color: isLast ? activeTextColor : textColor, bold: isLast)
            label.frame.origin = NSPoint(x: xOffset, y: (barHeight - label.frame.height) / 2)

            // Make all labels clickable
            let button = ClickableLabel(frame: label.frame)
            button.stringValue = component
            button.font = label.font
            button.textColor = label.textColor
            button.isBezeled = false
            button.drawsBackground = false
            button.isEditable = false
            button.isSelectable = false
            button.target = self
            button.tag = index
            button.action = isLast ? #selector(fileNameClicked(_:)) : #selector(pathComponentClicked(_:))
            button.sizeToFit()
            button.frame.origin = label.frame.origin
            addSubview(button)
            labels.append(button)
            xOffset += button.frame.width + 4
        }
    }

    @objc private func pathComponentClicked(_ sender: NSTextField) {
        guard let root = projectRoot else { return }

        // Build the directory URL from the breadcrumb index
        let clickedIndex = sender.tag
        var dirURL = root
        // pathComponents[0] is the project root name, pathComponents[1..n] are subdirs/file
        for i in 1...clickedIndex {
            dirURL = dirURL.appendingPathComponent(pathComponents[i])
        }

        // List sibling files/dirs in this directory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }

        let sorted = items.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }

        let menu = NSMenu()
        for item in sorted {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let title = isDir ? "\(item.lastPathComponent)/" : item.lastPathComponent
            let menuItem = NSMenuItem(title: title, action: #selector(breadcrumbFileSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            if isDir {
                menuItem.isEnabled = false // Directories not navigable in this simple version
            }
            menu.addItem(menuItem)
        }

        let location = NSPoint(x: sender.frame.origin.x, y: sender.frame.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    @objc private func breadcrumbFileSelected(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onFileSelected?(url)
    }

    @objc private func fileNameClicked(_ sender: NSTextField) {
        guard let requestSymbols = onRequestSymbols else { return }

        requestSymbols { [weak self] symbols in
            guard let self = self, !symbols.isEmpty else { return }
            self.showSymbolMenu(symbols, relativeTo: sender)
        }
    }

    private func showSymbolMenu(_ symbols: [LSPDocumentSymbol], relativeTo view: NSView) {
        let menu = NSMenu()

        func addSymbols(_ syms: [LSPDocumentSymbol], indent: Int) {
            for sym in syms {
                let prefix = String(repeating: "  ", count: indent)
                let icon = symbolIcon(for: sym.kind)
                let title = "\(prefix)\(icon) \(sym.name)"
                let item = NSMenuItem(title: title, action: #selector(symbolSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sym
                menu.addItem(item)

                if let children = sym.children, !children.isEmpty {
                    addSymbols(children, indent: indent + 1)
                }
            }
        }

        addSymbols(symbols, indent: 0)

        let location = NSPoint(x: view.frame.origin.x, y: view.frame.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    @objc private func symbolSelected(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? LSPDocumentSymbol else { return }
        onSymbolSelected?(symbol.selectionRange.start.line, symbol.selectionRange.start.character)
    }

    private func symbolIcon(for kind: Int) -> String {
        // LSP SymbolKind values
        switch kind {
        case 5: return "C"   // Class
        case 6: return "M"   // Method
        case 9: return "C"   // Constructor
        case 10: return "E"  // Enum
        case 11: return "I"  // Interface/Protocol
        case 12: return "F"  // Function
        case 13: return "V"  // Variable
        case 14: return "K"  // Constant
        case 23: return "S"  // Struct
        case 8: return "P"   // Property/Field
        case 22: return "E"  // Enum Member
        default: return "•"
        }
    }

    private func makeLabel(_ text: String, color: NSColor, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: bold ? .medium : .regular)
        label.textColor = color
        label.sizeToFit()
        return label
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        // Bottom border
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// NSTextField subclass that handles clicks
private class ClickableLabel: NSTextField {
    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
