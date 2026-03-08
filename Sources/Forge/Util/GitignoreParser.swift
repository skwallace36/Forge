import Foundation

/// Parses .gitignore files and provides path matching.
/// Supports basic patterns: wildcards (*), directory markers (/), negation (!), comments (#).
class GitignoreParser {

    struct Rule {
        let pattern: String
        let isNegation: Bool
        let isDirectoryOnly: Bool
        let regex: NSRegularExpression?
    }

    private var rules: [Rule] = []

    init(gitignoreURL: URL) {
        guard let content = try? String(contentsOf: gitignoreURL, encoding: .utf8) else { return }
        parse(content)
    }

    init(content: String) {
        parse(content)
    }

    private func parse(_ content: String) {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            var pattern = trimmed
            let isNegation = pattern.hasPrefix("!")
            if isNegation { pattern = String(pattern.dropFirst()) }

            let isDirectoryOnly = pattern.hasSuffix("/")
            if isDirectoryOnly { pattern = String(pattern.dropLast()) }

            // Strip leading slash (anchored to root)
            if pattern.hasPrefix("/") { pattern = String(pattern.dropFirst()) }

            guard let regex = gitignorePatternToRegex(pattern) else { continue }
            rules.append(Rule(pattern: pattern, isNegation: isNegation, isDirectoryOnly: isDirectoryOnly, regex: regex))
        }
    }

    /// Returns true if the path should be ignored
    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.isDirectoryOnly && !isDirectory { continue }
            guard let regex = rule.regex else { continue }

            let matchPath = relativePath
            let range = NSRange(location: 0, length: (matchPath as NSString).length)
            if regex.firstMatch(in: matchPath, range: range) != nil {
                ignored = !rule.isNegation
            }
        }
        return ignored
    }

    /// Convert a gitignore glob pattern to a regex
    private func gitignorePatternToRegex(_ pattern: String) -> NSRegularExpression? {
        var regex = ""

        // If pattern doesn't contain /, match against the basename only
        let matchFullPath = pattern.contains("/")

        if !matchFullPath {
            regex += "(?:^|/)"
        } else {
            regex += "^"
        }

        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            switch ch {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // ** matches any path component
                    regex += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex && pattern[i] == "/" {
                        i = pattern.index(after: i)
                    }
                    continue
                } else {
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            case "[":
                regex += "["
            case "]":
                regex += "]"
            default:
                regex += String(ch)
            }
            i = pattern.index(after: i)
        }

        regex += "$"

        return try? NSRegularExpression(pattern: regex, options: [])
    }
}
