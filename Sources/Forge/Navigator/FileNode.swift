import AppKit

class FileNode {

    let url: URL
    let isDirectory: Bool
    var children: [FileNode] = []
    private var childrenLoaded = false

    // Hidden files/dirs to skip
    private static let hiddenPrefixes: Set<String> = [".git", ".build", ".swiftpm", "DerivedData"]
    private static let hiddenNames: Set<String> = [".DS_Store", ".gitignore"]

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String {
        url.lastPathComponent
    }

    var icon: NSImage? {
        if isDirectory {
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "folder")
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
