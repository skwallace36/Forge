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
    }

    func save() throws {
        let text = textStorage.string
        try text.write(to: url, atomically: true, encoding: .utf8)
        isModified = false
    }
}
