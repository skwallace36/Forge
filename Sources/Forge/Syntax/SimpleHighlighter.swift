import AppKit

/// Simple regex-based syntax highlighting for non-tree-sitter languages.
/// Used for JSON, Markdown, YAML, and other common file types.
class SimpleHighlighter {

    let theme: Theme
    let fontSize: CGFloat
    private let rules: [HighlightRule]

    struct HighlightRule {
        let pattern: NSRegularExpression
        let captureName: String
    }

    init(theme: Theme, fontSize: CGFloat, language: String) {
        self.theme = theme
        self.fontSize = fontSize
        self.rules = SimpleHighlighter.rules(for: language)
    }

    func highlight(_ textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string as NSString

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.foreground,
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(defaultAttrs, range: fullRange)

        for rule in rules {
            let matches = rule.pattern.matches(in: text as String, range: fullRange)
            for match in matches {
                let range = match.range
                guard range.length > 0, NSMaxRange(range) <= textStorage.length else { continue }
                if let attrs = theme.attributes(for: rule.captureName, fontSize: fontSize) {
                    textStorage.addAttributes(attrs, range: range)
                }
            }
        }

        textStorage.endEditing()
    }

    // MARK: - Language Rules

    private static func rules(for language: String) -> [HighlightRule] {
        switch language.lowercased() {
        case "json":
            return jsonRules()
        case "markdown", "md":
            return markdownRules()
        case "yaml", "yml":
            return yamlRules()
        case "python", "py":
            return pythonRules()
        default:
            return genericRules()
        }
    }

    private static func jsonRules() -> [HighlightRule] {
        return [
            // Strings (keys and values)
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            // Numbers
            rule(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, "number"),
            // Booleans and null
            rule(#"\b(?:true|false|null)\b"#, "keyword"),
            // Colons (after keys)
            rule(#":"#, "punctuation"),
            // Brackets
            rule(#"[\[\]{}]"#, "punctuation.bracket"),
        ]
    }

    private static func markdownRules() -> [HighlightRule] {
        return [
            // Headers
            rule(#"^#{1,6}\s+.*$"#, "keyword", options: .anchorsMatchLines),
            // Bold
            rule(#"\*\*[^*]+\*\*"#, "keyword"),
            // Italic
            rule(#"\*[^*]+\*"#, "variable.parameter"),
            // Code blocks
            rule(#"```[\s\S]*?```"#, "string"),
            // Inline code
            rule(#"`[^`]+`"#, "string"),
            // Links
            rule(#"\[([^\]]+)\]\([^)]+\)"#, "function"),
            // URLs
            rule(#"https?://\S+"#, "function"),
            // List markers
            rule(#"^[\s]*[-*+]\s"#, "keyword", options: .anchorsMatchLines),
            // Numbered lists
            rule(#"^[\s]*\d+\.\s"#, "keyword", options: .anchorsMatchLines),
            // Blockquotes
            rule(#"^>\s+.*$"#, "comment", options: .anchorsMatchLines),
        ]
    }

    private static func yamlRules() -> [HighlightRule] {
        return [
            // Comments
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            // Keys
            rule(#"^[\s]*[\w.-]+(?=\s*:)"#, "keyword", options: .anchorsMatchLines),
            // Strings
            rule(#""[^"]*""#, "string"),
            rule(#"'[^']*'"#, "string"),
            // Numbers
            rule(#"\b\d+(?:\.\d+)?\b"#, "number"),
            // Booleans
            rule(#"\b(?:true|false|yes|no|on|off|null)\b"#, "keyword"),
        ]
    }

    private static func pythonRules() -> [HighlightRule] {
        return [
            // Comments
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            // Triple-quoted strings
            rule(#"\"\"\"[\s\S]*?\"\"\""#, "string"),
            rule(#"'''[\s\S]*?'''"#, "string"),
            // Strings
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, "string"),
            // Keywords
            rule(#"\b(?:def|class|import|from|return|if|elif|else|for|while|break|continue|pass|raise|try|except|finally|with|as|yield|lambda|and|or|not|in|is|None|True|False|self|async|await|global|nonlocal)\b"#, "keyword"),
            // Numbers
            rule(#"\b\d+(?:\.\d+)?\b"#, "number"),
            // Decorators
            rule(#"@\w+"#, "attribute"),
            // Function definitions
            rule(#"(?<=def\s)\w+"#, "function"),
            // Class definitions
            rule(#"(?<=class\s)\w+"#, "type"),
        ]
    }

    private static func genericRules() -> [HighlightRule] {
        return [
            // Line comments
            rule(#"//.*$"#, "comment", options: .anchorsMatchLines),
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            // Strings
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, "string"),
            // Numbers
            rule(#"\b\d+(?:\.\d+)?\b"#, "number"),
        ]
    }

    private static func rule(_ pattern: String, _ captureName: String, options: NSRegularExpression.Options = []) -> HighlightRule {
        return HighlightRule(
            pattern: try! NSRegularExpression(pattern: pattern, options: options),
            captureName: captureName
        )
    }
}
