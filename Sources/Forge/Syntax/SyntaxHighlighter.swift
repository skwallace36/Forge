import AppKit
import SwiftTreeSitter
import TreeSitterSwift

/// Manages tree-sitter parsing and syntax highlighting for a document.
class SyntaxHighlighter {

    let theme: Theme
    let fontSize: CGFloat

    private let parser: Parser
    private let language: Language
    private let highlightQuery: Query?
    private var currentTree: MutableTree?

    init(theme: Theme = .xcodeDefaultDark, fontSize: CGFloat = 13) {
        self.theme = theme
        self.fontSize = fontSize

        self.parser = Parser()
        let lang = Language(language: tree_sitter_swift())
        self.language = lang

        try? parser.setLanguage(lang)

        // Load highlight queries from the bundled grammar package
        self.highlightQuery = SyntaxHighlighter.loadHighlightQuery(for: lang)
    }

    /// Parse the full text and return a tree.
    func parse(_ text: String) {
        currentTree = parser.parse(text)
    }

    /// Incremental parse after an edit.
    func incrementalParse(
        startByte: UInt32,
        oldEndByte: UInt32,
        newEndByte: UInt32,
        startPoint: Point,
        oldEndPoint: Point,
        newEndPoint: Point,
        newText: String
    ) {
        let edit = InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
        currentTree?.edit(edit)
        currentTree = parser.parse(tree: currentTree, string: newText)
    }

    /// Apply syntax highlighting to a text storage.
    func highlight(_ textStorage: NSTextStorage) {
        guard let tree = currentTree, let query = highlightQuery else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Reset to default style
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.foreground,
            .font: Preferences.shared.editorFont(size: fontSize),
        ]
        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttrs, range: fullRange)

        // Execute query
        let cursor = query.execute(in: tree)
        cursor.setRange(fullRange)
        cursor.matchLimit = 512

        while let match = cursor.next() {
            for capture in match.captures {
                guard let name = capture.name else { continue }

                let range = capture.range
                guard range.location != NSNotFound,
                      range.length > 0,
                      NSMaxRange(range) <= textStorage.length else {
                    continue
                }

                if let attrs = theme.attributes(for: name, fontSize: fontSize) {
                    textStorage.addAttributes(attrs, range: range)
                }
            }
        }

        textStorage.endEditing()
    }

    /// Apply highlighting to a visible range only (for performance).
    func highlight(_ textStorage: NSTextStorage, in visibleRange: NSRange) {
        guard let tree = currentTree, let query = highlightQuery else { return }

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.foreground,
            .font: Preferences.shared.editorFont(size: fontSize),
        ]
        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttrs, range: visibleRange)

        let cursor = query.execute(in: tree)
        cursor.setRange(visibleRange)
        cursor.matchLimit = 512

        while let match = cursor.next() {
            for capture in match.captures {
                guard let name = capture.name else { continue }

                let range = capture.range
                guard range.location != NSNotFound,
                      range.length > 0,
                      NSMaxRange(range) <= textStorage.length else {
                    continue
                }

                // Only apply within visible range
                let intersection = NSIntersectionRange(range, visibleRange)
                if intersection.length > 0,
                   let attrs = theme.attributes(for: name, fontSize: fontSize) {
                    textStorage.addAttributes(attrs, range: intersection)
                }
            }
        }

        textStorage.endEditing()
    }

    // MARK: - Query Loading

    private static func loadHighlightQuery(for language: Language) -> Query? {
        // Try to load from TreeSitterSwift bundle
        let bundleName = "TreeSitterSwift_TreeSitterSwift"
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.contains(bundleName) }),
           let queryURL = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries") {
            if let querySource = try? String(contentsOf: queryURL),
               let queryData = querySource.data(using: .utf8),
               let query = try? Query(language: language, data: queryData) {
                return query
            }
        }

        // Fallback: search all bundles for highlights.scm
        for bundle in Bundle.allBundles {
            if let queryURL = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries") {
                if let querySource = try? String(contentsOf: queryURL),
                   let queryData = querySource.data(using: .utf8),
                   let query = try? Query(language: language, data: queryData) {
                    return query
                }
            }
        }

        // Last resort: use embedded minimal query
        guard let queryData = SyntaxHighlighter.minimalSwiftQuery.data(using: .utf8) else { return nil }
        return try? Query(language: language, data: queryData)
    }

    /// Highlight query for Swift — uses node types from tree-sitter-swift 0.7.x
    private static let minimalSwiftQuery = """
    ; Keywords
    ["func" "var" "let" "class" "struct" "enum" "protocol" "extension"
     "import" "return" "if" "else" "guard" "switch" "case" "default"
     "for" "while" "repeat" "break" "continue" "in" "where" "do" "try"
     "catch" "throw" "throws" "nil" "true" "false"
     "self" "Self" "super" "init" "deinit" "typealias"
     "static" "private" "fileprivate" "internal" "public" "open"
     "override" "mutating" "weak" "lazy"
     "final" "required" "convenience"
     "as" "is" "get" "set" "willSet" "didSet"
    ] @keyword

    ; Strings
    (line_string_literal) @string

    ; Comments
    (comment) @comment

    ; Numbers
    (integer_literal) @number
    (real_literal) @number
    (boolean_literal) @number

    ; Types
    (type_identifier) @type

    ; Functions
    (function_declaration name: (simple_identifier) @function)
    (call_expression (simple_identifier) @function.call)

    ; Attributes
    (attribute) @attribute
    """
}
