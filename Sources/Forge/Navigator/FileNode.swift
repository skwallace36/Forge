import AppKit

class FileNode {

    let url: URL
    let isDirectory: Bool
    var children: [FileNode] = []
    private var childrenLoaded = false

    // Hidden files/dirs to skip
    private static let hiddenPrefixes: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "xcuserdata",
    ]
    private static let hiddenNames: Set<String> = [
        ".DS_Store", ".gitignore", "node_modules", "Pods",
        "__pycache__", ".vscode", ".idea",
    ]
    private static let hiddenExtensions: Set<String> = [
        "o", "a", "dylib",
    ]

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String {
        url.lastPathComponent
    }

    var icon: NSImage? {
        if isDirectory {
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "folder")?
                .withSymbolConfiguration(.init(paletteColors: [.init(red: 0.40, green: 0.60, blue: 0.90, alpha: 1.0)]))
        }
        return fileIcon(for: url.pathExtension)
    }

    private func fileIcon(for ext: String) -> NSImage? {
        let (symbolName, color) = FileNode.iconInfo(for: ext)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: ext)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    private static func iconInfo(for ext: String) -> (String, NSColor) {
        switch ext.lowercased() {
        case "swift":
            return ("swift", NSColor(red: 0.99, green: 0.55, blue: 0.25, alpha: 1.0))
        case "json":
            return ("curlybraces", NSColor(red: 0.90, green: 0.80, blue: 0.30, alpha: 1.0))
        case "md", "markdown":
            return ("doc.text", NSColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1.0))
        case "py":
            return ("chevron.left.forwardslash.chevron.right", NSColor(red: 0.30, green: 0.70, blue: 0.90, alpha: 1.0))
        case "js", "ts", "jsx", "tsx":
            return ("chevron.left.forwardslash.chevron.right", NSColor(red: 0.95, green: 0.85, blue: 0.30, alpha: 1.0))
        case "yml", "yaml":
            return ("doc.text", NSColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1.0))
        case "resolved":
            return ("lock.fill", NSColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1.0))
        case "h":
            return ("h.square", NSColor(red: 0.60, green: 0.80, blue: 0.40, alpha: 1.0))
        case "c", "m", "mm", "cpp":
            return ("c.square", NSColor(red: 0.50, green: 0.70, blue: 0.95, alpha: 1.0))
        default:
            return ("doc", NSColor(red: 0.60, green: 0.60, blue: 0.65, alpha: 1.0))
        }
    }

    /// Force reloads children from disk (used by file watcher)
    func reloadChildren() {
        childrenLoaded = false
        children = []
        loadChildren()
    }

    func loadChildren() {
        guard isDirectory, !childrenLoaded else { return }
        childrenLoaded = true

        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        children = urls
            .filter { url in
                let name = url.lastPathComponent
                if FileNode.hiddenPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
                if FileNode.hiddenNames.contains(name) { return false }
                if FileNode.hiddenExtensions.contains(url.pathExtension.lowercased()) { return false }
                return true
            }
            .map { childURL in
                let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: childURL, isDirectory: isDir)
            }
            .sorted { a, b in
                // Directories first, then alphabetical
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

