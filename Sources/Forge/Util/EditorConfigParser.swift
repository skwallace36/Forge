import Foundation

/// Parses `.editorconfig` files and returns settings for a given file path.
/// Supports: indent_style, indent_size, tab_width, end_of_line, trim_trailing_whitespace,
/// insert_final_newline, charset.
class EditorConfigParser {

    struct Settings {
        var indentStyle: IndentStyle?
        var indentSize: Int?
        var tabWidth: Int?
        var endOfLine: EndOfLine?
        var trimTrailingWhitespace: Bool?
        var insertFinalNewline: Bool?
        var charset: String?

        enum IndentStyle { case space, tab }
        enum EndOfLine { case lf, crlf, cr }

        /// Effective tab/indent width, resolving defaults
        var effectiveIndentSize: Int? {
            if let size = indentSize { return size }
            if let tw = tabWidth { return tw }
            return nil
        }
    }

    private struct Section {
        let glob: String
        let properties: [String: String]
    }

    private var sections: [Section] = []
    private(set) var isRoot: Bool = false

    init?(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        parse(content)
    }

    private func parse(_ content: String) {
        var currentGlob: String? = nil
        var currentProps: [String: String] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous section
                if let glob = currentGlob {
                    sections.append(Section(glob: glob, properties: currentProps))
                }
                currentGlob = String(trimmed.dropFirst().dropLast())
                currentProps = [:]
                continue
            }

            // Key = value
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()

                if currentGlob == nil {
                    // Root-level property
                    if key == "root" && value == "true" {
                        isRoot = true
                    }
                } else {
                    currentProps[key] = value
                }
            }
        }

        // Save last section
        if let glob = currentGlob {
            sections.append(Section(glob: glob, properties: currentProps))
        }
    }

    /// Get settings for a file path (relative to the .editorconfig directory)
    func settings(for relativePath: String) -> Settings {
        var result = Settings()
        let fileName = (relativePath as NSString).lastPathComponent

        for section in sections {
            if matchesGlob(section.glob, path: relativePath, fileName: fileName) {
                applyProperties(section.properties, to: &result)
            }
        }

        return result
    }

    private func matchesGlob(_ glob: String, path: String, fileName: String) -> Bool {
        // Handle common glob patterns
        if glob == "*" {
            return true
        }

        // Simple extension match: *.ext
        if glob.hasPrefix("*.") && !glob.contains("/") && !glob.contains("{") {
            let ext = String(glob.dropFirst(2))
            return fileName.hasSuffix(".\(ext)")
        }

        // Brace expansion: *.{ext1,ext2}
        if glob.hasPrefix("*.{") && glob.hasSuffix("}") {
            let inner = String(glob.dropFirst(3).dropLast(1))
            let extensions = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return extensions.contains { fileName.hasSuffix(".\($0)") }
        }

        // Exact filename match (e.g., Makefile)
        if !glob.contains("*") && !glob.contains("/") {
            return fileName == glob
        }

        // Path-based glob with ** (match anything)
        if glob.contains("**") {
            let parts = glob.components(separatedBy: "**/")
            if parts.count == 2 {
                let suffix = parts[1]
                if suffix.hasPrefix("*.") {
                    let ext = String(suffix.dropFirst(2))
                    return fileName.hasSuffix(".\(ext)")
                }
                return path.hasSuffix(suffix) || fileName == suffix
            }
        }

        return false
    }

    private func applyProperties(_ props: [String: String], to settings: inout Settings) {
        if let style = props["indent_style"] {
            switch style {
            case "space": settings.indentStyle = .space
            case "tab": settings.indentStyle = .tab
            default: break
            }
        }

        if let sizeStr = props["indent_size"], let size = Int(sizeStr) {
            settings.indentSize = size
        }

        if let twStr = props["tab_width"], let tw = Int(twStr) {
            settings.tabWidth = tw
        }

        if let eol = props["end_of_line"] {
            switch eol {
            case "lf": settings.endOfLine = .lf
            case "crlf": settings.endOfLine = .crlf
            case "cr": settings.endOfLine = .cr
            default: break
            }
        }

        if let trim = props["trim_trailing_whitespace"] {
            settings.trimTrailingWhitespace = (trim == "true")
        }

        if let newline = props["insert_final_newline"] {
            settings.insertFinalNewline = (newline == "true")
        }

        if let charset = props["charset"] {
            settings.charset = charset
        }
    }

    /// Search for .editorconfig files from the file's directory up to the project root.
    /// Returns merged settings (closest file wins for each property).
    static func settings(for fileURL: URL, projectRoot: URL) -> Settings {
        var result = Settings()
        var dir = fileURL.deletingLastPathComponent()
        let rootPath = projectRoot.standardizedFileURL.path

        // Collect .editorconfig files from file's dir up to project root
        var configs: [(parser: EditorConfigParser, dir: URL)] = []

        while true {
            let configURL = dir.appendingPathComponent(".editorconfig")
            if let parser = EditorConfigParser(url: configURL) {
                configs.append((parser, dir))
                if parser.isRoot { break }
            }
            let parentDir = dir.deletingLastPathComponent()
            if parentDir.path == dir.path { break }
            if !dir.standardizedFileURL.path.hasPrefix(rootPath) { break }
            dir = parentDir
        }

        // Apply from outermost to innermost (innermost wins)
        for (parser, configDir) in configs.reversed() {
            let relativePath = fileURL.path.replacingOccurrences(of: configDir.path + "/", with: "")
            let sectionSettings = parser.settings(for: relativePath)
            merge(sectionSettings, into: &result)
        }

        return result
    }

    private static func merge(_ source: Settings, into target: inout Settings) {
        if let v = source.indentStyle { target.indentStyle = v }
        if let v = source.indentSize { target.indentSize = v }
        if let v = source.tabWidth { target.tabWidth = v }
        if let v = source.endOfLine { target.endOfLine = v }
        if let v = source.trimTrailingWhitespace { target.trimTrailingWhitespace = v }
        if let v = source.insertFinalNewline { target.insertFinalNewline = v }
        if let v = source.charset { target.charset = v }
    }
}
