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

    /// Provider for the current document text (for MARK comment extraction)
    var documentTextProvider: (() -> String?)?

    /// Cached document symbols for scope lookup
    private var cachedSymbols: [LSPDocumentSymbol] = []

    /// Current scope display label
    private var scopeLabel: ClickableLabel?
    private var scopeSeparator: NSTextField?

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
        cachedSymbols = []

        // Clear old views
        labels.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        separators.removeAll()
        scopeLabel?.removeFromSuperview()
        scopeLabel = nil
        scopeSeparator?.removeFromSuperview()
        scopeSeparator = nil

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

    // MARK: - Scope Display

    /// Update cached document symbols (call when file opens or text changes)
    func updateSymbols(_ symbols: [LSPDocumentSymbol]) {
        cachedSymbols = symbols
    }

    /// Update the current scope display based on cursor position (0-indexed line, column)
    func updateScope(line: Int, column: Int) {
        // Try LSP symbols first, fall back to regex-based detection
        if !cachedSymbols.isEmpty {
            let scopeName = findContainingSymbol(line: line, column: column)
            updateScopeLabel(scopeName)
        } else if let text = documentTextProvider?() {
            let scopeName = findScopeByRegex(in: text, line: line)
            updateScopeLabel(scopeName)
        }
    }

    /// Find the deepest symbol containing the cursor position, returning a scope path
    private func findContainingSymbol(line: Int, column: Int) -> String? {
        // Type-level symbol kinds (class, enum, interface/protocol, struct, module/namespace)
        let typeKinds: Set<Int> = [5, 10, 11, 23, 2]

        // Walk the tree collecting the scope path
        var path: [String] = []

        func search(_ symbols: [LSPDocumentSymbol]) {
            for sym in symbols {
                let r = sym.range
                let inRange = (line > r.start.line || (line == r.start.line && column >= r.start.character))
                    && (line < r.end.line || (line == r.end.line && column <= r.end.character))

                guard inRange else { continue }

                // Add this symbol to the path
                if typeKinds.contains(sym.kind) {
                    path.append(sym.name)
                    // Search children for deeper match
                    if let children = sym.children, !children.isEmpty {
                        search(children)
                    }
                    return
                } else {
                    // Non-type symbol (function, property, etc.) — this is the leaf
                    path.append(sym.name)
                    return
                }
            }
        }

        search(cachedSymbols)
        return path.isEmpty ? nil : path.joined(separator: " › ")
    }

    /// Regex-based scope detection for when LSP symbols aren't available
    private func findScopeByRegex(in text: String, line: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line < lines.count else { return nil }

        // Scan backwards from cursor line to find the nearest scope-defining line
        // Track brace depth to handle nested scopes
        let scopePattern = try? NSRegularExpression(
            pattern: #"^\s*(?:(?:public|private|internal|fileprivate|open|static|override|final|class|@objc)\s+)*(?:func|class|struct|enum|protocol|extension|init|deinit|var|let)\s+(\S+)"#,
            options: []
        )
        guard let pattern = scopePattern else { return nil }

        var braceDepth = 0
        // Count braces from cursor line down (to track where we are)
        for i in stride(from: line, through: 0, by: -1) {
            let ln = lines[i]
            for ch in ln {
                if ch == "}" { braceDepth += 1 }
                else if ch == "{" { braceDepth -= 1 }
            }

            if braceDepth <= 0 {
                let nsLine = ln as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                if let match = pattern.firstMatch(in: ln, range: range), match.numberOfRanges > 1 {
                    let nameRange = match.range(at: 1)
                    var name = nsLine.substring(with: nameRange)
                    // Clean up: remove trailing ( or { or :
                    while name.hasSuffix("(") || name.hasSuffix("{") || name.hasSuffix(":") || name.hasSuffix("<") {
                        name = String(name.dropLast())
                    }
                    if !name.isEmpty { return name }
                }
            }
        }
        return nil
    }

    private func updateScopeLabel(_ text: String?) {
        // Remove existing scope display
        scopeLabel?.removeFromSuperview()
        scopeLabel = nil
        scopeSeparator?.removeFromSuperview()
        scopeSeparator = nil

        guard let text = text, !text.isEmpty else { return }

        // Find the rightmost label position
        let lastX = labels.last.map { $0.frame.maxX + 4 } ?? CGFloat(10)

        // Add separator
        let sep = makeLabel("›", color: separatorColor, bold: false)
        sep.frame.origin = NSPoint(x: lastX, y: (barHeight - sep.frame.height) / 2)
        addSubview(sep)
        scopeSeparator = sep

        // Add scope label
        let label = ClickableLabel(frame: .zero)
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(red: 0.55, green: 0.72, blue: 0.92, alpha: 1.0) // blue-ish for scope
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.target = self
        label.action = #selector(fileNameClicked(_:)) // Same as clicking filename — shows symbol list
        label.sizeToFit()
        label.frame.origin = NSPoint(x: lastX + sep.frame.width + 4, y: (barHeight - label.frame.height) / 2)
        addSubview(label)
        scopeLabel = label
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
            let menuItem = NSMenuItem(title: title, action: isDir ? nil : #selector(breadcrumbFileSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            if isDir {
                // Build a submenu listing the directory's contents
                menuItem.submenu = buildDirectorySubmenu(for: item)
            }
            menu.addItem(menuItem)
        }

        let location = NSPoint(x: sender.frame.origin.x, y: sender.frame.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    /// Build a recursive submenu for a directory's contents
    private func buildDirectorySubmenu(for dirURL: URL, depth: Int = 0) -> NSMenu {
        let submenu = NSMenu()
        guard depth < 3 else { return submenu } // Limit nesting depth

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return submenu
        }

        let sorted = items.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }

        for item in sorted {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let title = isDir ? "\(item.lastPathComponent)/" : item.lastPathComponent
            let menuItem = NSMenuItem(title: title, action: isDir ? nil : #selector(breadcrumbFileSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            if isDir {
                menuItem.submenu = buildDirectorySubmenu(for: item, depth: depth + 1)
            }
            submenu.addItem(menuItem)
        }

        return submenu
    }

    @objc private func breadcrumbFileSelected(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onFileSelected?(url)
    }

    @objc private func fileNameClicked(_ sender: NSTextField) {
        // Extract MARK comments from document text
        let markAnnotations = extractMarkAnnotations()

        if let requestSymbols = onRequestSymbols {
            requestSymbols { [weak self] symbols in
                guard let self = self else { return }
                if symbols.isEmpty && markAnnotations.isEmpty { return }
                self.showSymbolMenu(symbols, marks: markAnnotations, relativeTo: sender)
            }
        } else if !markAnnotations.isEmpty {
            showSymbolMenu([], marks: markAnnotations, relativeTo: sender)
        }
    }

    /// Extract // MARK: comments with their line numbers
    private func extractMarkAnnotations() -> [(line: Int, text: String)] {
        guard let text = documentTextProvider?() else { return [] }
        var results: [(line: Int, text: String)] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("// MARK:") {
                let label = String(trimmed.dropFirst("// MARK:".count)).trimmingCharacters(in: .whitespaces)
                results.append((line: i, text: label))
            }
        }
        return results
    }

    private func showSymbolMenu(_ symbols: [LSPDocumentSymbol], marks: [(line: Int, text: String)], relativeTo view: NSView) {
        let menu = NSMenu()

        // Merge symbols and marks by line number
        struct MenuEntry {
            let line: Int
            let isMark: Bool
            let markText: String?
            let symbol: LSPDocumentSymbol?
            let indent: Int
        }

        var entries: [MenuEntry] = []

        // Add MARK annotations
        for mark in marks {
            entries.append(MenuEntry(line: mark.line, isMark: true, markText: mark.text, symbol: nil, indent: 0))
        }

        // Add top-level symbols (flatten for the menu)
        func collectSymbols(_ syms: [LSPDocumentSymbol], indent: Int) {
            for sym in syms {
                entries.append(MenuEntry(
                    line: sym.selectionRange.start.line,
                    isMark: false,
                    markText: nil,
                    symbol: sym,
                    indent: indent
                ))
                if let children = sym.children, !children.isEmpty {
                    collectSymbols(children, indent: indent + 1)
                }
            }
        }
        collectSymbols(symbols, indent: 0)

        // Sort by line number
        entries.sort { $0.line < $1.line }

        for entry in entries {
            if entry.isMark {
                // MARK as a disabled section header with separator
                let text = entry.markText ?? ""
                if text.hasPrefix("- ") || text.hasPrefix("-") {
                    // "MARK: - Foo" style — add separator above
                    menu.addItem(.separator())
                    let cleanText = text.hasPrefix("- ") ? String(text.dropFirst(2)) : String(text.dropFirst(1))
                    if !cleanText.isEmpty {
                        let item = NSMenuItem(title: cleanText, action: #selector(markSelected(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = entry.line
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                            .foregroundColor: NSColor(white: 0.75, alpha: 1.0),
                        ]
                        item.attributedTitle = NSAttributedString(string: cleanText, attributes: attrs)
                        menu.addItem(item)
                    }
                } else if !text.isEmpty {
                    let item = NSMenuItem(title: text, action: #selector(markSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = entry.line
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor(white: 0.65, alpha: 1.0),
                    ]
                    item.attributedTitle = NSAttributedString(string: text, attributes: attrs)
                    menu.addItem(item)
                }
            } else if let sym = entry.symbol {
                let prefix = String(repeating: "  ", count: entry.indent)
                let icon = symbolIcon(for: sym.kind)
                let title = "\(prefix)\(icon) \(sym.name)"
                let item = NSMenuItem(title: title, action: #selector(symbolSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sym
                menu.addItem(item)
            }
        }

        let location = NSPoint(x: view.frame.origin.x, y: view.frame.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    @objc private func markSelected(_ sender: NSMenuItem) {
        onSymbolSelected?(sender.tag, 0)
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
