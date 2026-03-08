import AppKit

class ForgeDocument {

    let url: URL
    let textStorage: NSTextStorage
    var isModified: Bool = false
    let undoManager = UndoManager()
    /// Whether this file appears to be a binary (non-text) file
    private(set) var isBinary: Bool = false

    /// Remembered cursor position (selection range) for this document
    var savedSelectionRange: NSRange?
    /// Remembered scroll position for this document
    var savedScrollPosition: NSPoint?
    /// Last known modification date of the file on disk
    private(set) var lastModifiedDate: Date?

    init(url: URL) {
        self.url = url
        self.textStorage = NSTextStorage()
        loadFromDisk()
    }

    var fileName: String {
        url.lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: url) else { return }

        // Detect binary files by checking for null bytes in the first 8KB
        let checkLength = min(data.count, 8192)
        let slice = data.prefix(checkLength)
        if slice.contains(0x00) {
            isBinary = true
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            isBinary = true
            return
        }

        isBinary = false
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.endEditing()
        isModified = false
        lastModifiedDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Returns true if the file has been modified on disk since we last read it
    func hasChangedOnDisk() -> Bool {
        guard let lastMod = lastModifiedDate,
              let currentMod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return false
        }
        return currentMod > lastMod
    }

    /// File size in bytes
    var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    func save() throws {
        var text = textStorage.string

        // Trim trailing whitespace from each line
        let lines = text.components(separatedBy: "\n")
        let trimmed = lines.map { line in
            var s = line
            while s.hasSuffix(" ") || s.hasSuffix("\t") {
                s.removeLast()
            }
            return s
        }
        text = trimmed.joined(separator: "\n")

        // Ensure file ends with a single newline
        if !text.isEmpty && !text.hasSuffix("\n") {
            text.append("\n")
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        isModified = false
        lastModifiedDate = Date()
    }
}
