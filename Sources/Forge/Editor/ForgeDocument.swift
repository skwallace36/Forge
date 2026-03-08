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

    /// Detected indent style for this file (nil = use global preference)
    private(set) var detectedTabWidth: Int?
    /// Whether this file uses tabs (nil = use global preference)
    private(set) var detectedUseTabs: Bool?

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
        detectIndentStyle(text)
    }

    /// Analyze file content to detect indent style (tabs vs spaces, width)
    private func detectIndentStyle(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let sampleLines = lines.prefix(200)

        var tabCount = 0
        var spaceCount = 0
        var spaceCounts: [Int: Int] = [:]  // indent width → frequency

        for line in sampleLines {
            guard !line.isEmpty else { continue }
            let first = line.first!
            if first == "\t" {
                tabCount += 1
            } else if first == " " {
                spaceCount += 1
                // Count leading spaces
                var spaces = 0
                for ch in line {
                    if ch == " " { spaces += 1 } else { break }
                }
                if spaces > 0 && spaces <= 16 {
                    spaceCounts[spaces, default: 0] += 1
                }
            }
        }

        // Need at least 3 indented lines to make a detection
        guard tabCount + spaceCount >= 3 else { return }

        if tabCount > spaceCount {
            detectedUseTabs = true
            detectedTabWidth = nil
        } else {
            detectedUseTabs = false
            // Find the most common smallest indent difference
            // Look for common widths: 2, 4, 8
            let candidates = [2, 4, 8]
            var bestWidth = 4
            var bestScore = 0
            for width in candidates {
                let score = spaceCounts.reduce(0) { sum, entry in
                    entry.key % width == 0 ? sum + entry.value : sum
                }
                if score > bestScore {
                    bestScore = score
                    bestWidth = width
                }
            }
            detectedTabWidth = bestWidth
        }
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
        let prefs = Preferences.shared

        // Trim trailing whitespace from each line
        if prefs.trimTrailingWhitespace {
            let lines = text.components(separatedBy: "\n")
            let trimmed = lines.map { line in
                var s = line
                while s.hasSuffix(" ") || s.hasSuffix("\t") {
                    s.removeLast()
                }
                return s
            }
            text = trimmed.joined(separator: "\n")
        }

        // Ensure file ends with a single newline
        if prefs.ensureTrailingNewline && !text.isEmpty && !text.hasSuffix("\n") {
            text.append("\n")
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        isModified = false
        lastModifiedDate = Date()
    }
}
