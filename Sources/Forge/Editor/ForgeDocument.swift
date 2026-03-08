import AppKit

class ForgeDocument {

    let url: URL
    let textStorage: NSTextStorage
    var isModified: Bool = false
    let undoManager = UndoManager()

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
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
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
