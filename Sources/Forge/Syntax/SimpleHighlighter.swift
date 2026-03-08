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
        case "js", "jsx", "ts", "tsx":
            return jsRules()
        case "html", "xml":
            return htmlRules()
        case "css":
            return cssRules()
        case "sh", "bash", "zsh":
            return shellRules()
        case "rb":
            return rubyRules()
        case "go":
            return goRules()
        case "rs":
            return rustRules()
        case "toml":
            return tomlRules()
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

    private static func jsRules() -> [HighlightRule] {
        return [
            rule(#"//.*$"#, "comment", options: .anchorsMatchLines),
            rule(#"/\*[\s\S]*?\*/"#, "comment"),
            rule(#"`[^`]*`"#, "string"),
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, "string"),
            rule(#"\b(?:const|let|var|function|return|if|else|for|while|do|break|continue|switch|case|default|throw|try|catch|finally|class|extends|import|export|from|new|this|super|async|await|yield|of|in|typeof|instanceof|void|delete|null|undefined|true|false|static|get|set|constructor)\b"#, "keyword"),
            rule(#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, "number"),
            rule(#"(?<=function\s)\w+"#, "function"),
            rule(#"(?<=class\s)\w+"#, "type"),
            rule(#"=>"#, "keyword"),
        ]
    }

    private static func htmlRules() -> [HighlightRule] {
        return [
            rule(#"<!--[\s\S]*?-->"#, "comment"),
            rule(#"</?[\w-]+"#, "keyword"),
            rule(#"/?\s*>"#, "keyword"),
            rule(#"\b[\w-]+(?=\s*=)"#, "variable.parameter"),
            rule(#""[^"]*""#, "string"),
            rule(#"'[^']*'"#, "string"),
        ]
    }

    private static func cssRules() -> [HighlightRule] {
        return [
            rule(#"/\*[\s\S]*?\*/"#, "comment"),
            rule(#"[.#][\w-]+"#, "function"),
            rule(#"[\w-]+(?=\s*:)"#, "keyword"),
            rule(#""[^"]*""#, "string"),
            rule(#"'[^']*'"#, "string"),
            rule(#"\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|pt|deg|s|ms)?\b"#, "number"),
            rule(#"#[0-9a-fA-F]{3,8}\b"#, "number"),
            rule(#"@[\w-]+"#, "attribute"),
        ]
    }

    private static func shellRules() -> [HighlightRule] {
        return [
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"'[^']*'"#, "string"),
            rule(#"\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|local|export|source|exit|break|continue|shift|eval|exec|set|unset|readonly|declare|typeset)\b"#, "keyword"),
            rule(#"\$\{?[\w@#?*!]+\}?"#, "variable.parameter"),
            rule(#"\b\d+\b"#, "number"),
        ]
    }

    private static func rubyRules() -> [HighlightRule] {
        return [
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, "string"),
            rule(#"\b(?:def|end|class|module|if|elsif|else|unless|while|until|for|do|begin|rescue|ensure|raise|return|yield|block_given\?|require|include|extend|attr_accessor|attr_reader|attr_writer|self|super|nil|true|false|and|or|not|in|then|when|case|lambda|proc)\b"#, "keyword"),
            rule(#"\b\d+(?:\.\d+)?\b"#, "number"),
            rule(#"@\w+"#, "variable.parameter"),
            rule(#":\w+"#, "string"),
            rule(#"(?<=def\s)\w+"#, "function"),
            rule(#"(?<=class\s)\w+"#, "type"),
        ]
    }

    private static func goRules() -> [HighlightRule] {
        return [
            rule(#"//.*$"#, "comment", options: .anchorsMatchLines),
            rule(#"/\*[\s\S]*?\*/"#, "comment"),
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"`[^`]*`"#, "string"),
            rule(#"\b(?:func|return|if|else|for|range|switch|case|default|break|continue|go|select|chan|defer|fallthrough|goto|map|struct|interface|package|import|var|const|type|nil|true|false|iota|make|new|len|cap|append|delete|copy|close|panic|recover)\b"#, "keyword"),
            rule(#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, "number"),
            rule(#"(?<=func\s)\w+"#, "function"),
            rule(#"(?<=type\s)\w+"#, "type"),
        ]
    }

    private static func rustRules() -> [HighlightRule] {
        return [
            rule(#"//.*$"#, "comment", options: .anchorsMatchLines),
            rule(#"/\*[\s\S]*?\*/"#, "comment"),
            rule(#""[^"\\]*(?:\\.[^"\\]*)*""#, "string"),
            rule(#"\b(?:fn|let|mut|const|static|struct|enum|impl|trait|pub|mod|use|crate|self|super|as|where|if|else|match|for|while|loop|break|continue|return|async|await|move|unsafe|extern|type|ref|in|true|false|Some|None|Ok|Err|Self)\b"#, "keyword"),
            rule(#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?:_\d+)*(?:u8|u16|u32|u64|u128|usize|i8|i16|i32|i64|i128|isize|f32|f64)?\b"#, "number"),
            rule(#"#\[[\w(,\s=")]*\]"#, "attribute"),
            rule(#"(?<=fn\s)\w+"#, "function"),
            rule(#"(?<=struct\s)\w+"#, "type"),
            rule(#"(?<=enum\s)\w+"#, "type"),
        ]
    }

    private static func tomlRules() -> [HighlightRule] {
        return [
            rule(#"#.*$"#, "comment", options: .anchorsMatchLines),
            rule(#"\[[\w.-]+\]"#, "keyword"),
            rule(#"[\w.-]+(?=\s*=)"#, "variable.parameter"),
            rule(#""[^"]*""#, "string"),
            rule(#"'[^']*'"#, "string"),
            rule(#"\b\d+(?:\.\d+)?\b"#, "number"),
            rule(#"\b(?:true|false)\b"#, "keyword"),
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
