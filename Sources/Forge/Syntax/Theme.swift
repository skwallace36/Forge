import AppKit

/// Syntax highlighting theme — maps tree-sitter capture names to text attributes.
struct Theme {

    struct Style {
        let color: NSColor
        let bold: Bool
        let italic: Bool

        init(_ color: NSColor, bold: Bool = false, italic: Bool = false) {
            self.color = color
            self.bold = bold
            self.italic = italic
        }
    }

    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let currentLine: NSColor
    let gutterBackground: NSColor
    let gutterForeground: NSColor
    let gutterCurrentLine: NSColor
    private let styles: [String: Style]

    func style(for captureName: String) -> Style? {
        // Try exact match first, then progressively strip suffixes
        // e.g. "keyword.function" -> "keyword.function", then "keyword"
        if let s = styles[captureName] { return s }
        let parts = captureName.split(separator: ".")
        if parts.count > 1 {
            let parent = String(parts[0])
            return styles[parent]
        }
        return nil
    }

    func attributes(for captureName: String, fontSize: CGFloat) -> [NSAttributedString.Key: Any]? {
        guard let style = style(for: captureName) else { return nil }
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: style.bold ? .bold : .regular)
        let font: NSFont
        if style.italic {
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
        } else {
            font = baseFont
        }
        return [
            .foregroundColor: style.color,
            .font: font,
        ]
    }

    // MARK: - Xcode Default Dark

    static let xcodeDefaultDark = Theme(
        name: "Xcode Default Dark",
        background: NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0),
        foreground: NSColor(white: 0.85, alpha: 1.0),
        cursor: NSColor.white,
        selection: NSColor(white: 1.0, alpha: 0.15),
        currentLine: NSColor(white: 1.0, alpha: 0.06),
        gutterBackground: NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0),
        gutterForeground: NSColor(white: 0.45, alpha: 1.0),
        gutterCurrentLine: NSColor(white: 0.75, alpha: 1.0),
        styles: [
            // Keywords
            "keyword":              Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0), bold: true),   // pink
            "keyword.return":       Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0), bold: true),
            "keyword.function":     Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0), bold: true),
            "keyword.operator":     Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0)),
            "include":              Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0), bold: true),   // import

            // Types
            "type":                 Style(NSColor(red: 0.35, green: 0.84, blue: 0.76, alpha: 1.0)),   // cyan/teal
            "type.builtin":         Style(NSColor(red: 0.35, green: 0.84, blue: 0.76, alpha: 1.0)),
            "constructor":          Style(NSColor(red: 0.35, green: 0.84, blue: 0.76, alpha: 1.0)),

            // Functions
            "function":             Style(NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0)),   // blue
            "function.method":      Style(NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0)),
            "function.call":        Style(NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0)),
            "method":               Style(NSColor(red: 0.40, green: 0.72, blue: 0.99, alpha: 1.0)),

            // Variables & Properties
            "variable":             Style(NSColor(white: 0.85, alpha: 1.0)),
            "variable.builtin":     Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0)),   // self, Self
            "variable.parameter":   Style(NSColor(red: 0.55, green: 0.75, blue: 0.99, alpha: 1.0)),
            "property":             Style(NSColor(red: 0.35, green: 0.84, blue: 0.76, alpha: 1.0)),

            // Strings
            "string":               Style(NSColor(red: 0.99, green: 0.42, blue: 0.33, alpha: 1.0)),   // red/orange
            "string.special":       Style(NSColor(red: 0.99, green: 0.42, blue: 0.33, alpha: 1.0)),
            "escape":               Style(NSColor(red: 0.85, green: 0.60, blue: 0.99, alpha: 1.0)),   // purple

            // Numbers
            "number":               Style(NSColor(red: 0.83, green: 0.78, blue: 0.54, alpha: 1.0)),   // yellow
            "float":                Style(NSColor(red: 0.83, green: 0.78, blue: 0.54, alpha: 1.0)),
            "boolean":              Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0), bold: true),

            // Comments
            "comment":              Style(NSColor(red: 0.42, green: 0.47, blue: 0.53, alpha: 1.0), italic: true),

            // Operators & Punctuation
            "operator":             Style(NSColor(white: 0.85, alpha: 1.0)),
            "punctuation":          Style(NSColor(white: 0.70, alpha: 1.0)),
            "punctuation.bracket":  Style(NSColor(white: 0.70, alpha: 1.0)),
            "punctuation.delimiter": Style(NSColor(white: 0.70, alpha: 1.0)),

            // Attributes & Preprocessor
            "attribute":            Style(NSColor(red: 0.85, green: 0.60, blue: 0.99, alpha: 1.0)),   // purple
            "label":                Style(NSColor(red: 0.55, green: 0.75, blue: 0.99, alpha: 1.0)),

            // Constants
            "constant":             Style(NSColor(red: 0.35, green: 0.84, blue: 0.76, alpha: 1.0)),
            "constant.builtin":     Style(NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1.0)),
        ]
    )
}
