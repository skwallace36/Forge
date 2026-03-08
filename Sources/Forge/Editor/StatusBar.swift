import AppKit

/// Bottom status bar showing cursor position, file info, etc.
class StatusBar: NSView {

    private let lineColLabel = NSTextField(labelWithString: "Ln 1, Col 1")
    private let fileTypeLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "UTF-8")
    private let lineEndingLabel = NSTextField(labelWithString: "LF")
    private let indentLabel = NSTextField(labelWithString: "Spaces: 4")
    private let branchLabel = NSTextField(labelWithString: "")
    private let diagnosticLabel = NSTextField(labelWithString: "")

    private let bgColor = NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
    private let textColor = NSColor(white: 0.55, alpha: 1.0)
    let barHeight: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // Monospaced digits for numeric labels, regular system font for text labels
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        let allLabels = [lineColLabel, fileTypeLabel, encodingLabel, lineEndingLabel, indentLabel, branchLabel, diagnosticLabel]
        for label in allLabels {
            label.textColor = textColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        lineColLabel.font = monoFont
        indentLabel.font = monoFont
        encodingLabel.font = textFont
        lineEndingLabel.font = textFont
        fileTypeLabel.font = textFont
        branchLabel.font = textFont
        diagnosticLabel.font = textFont

        NSLayoutConstraint.activate([
            lineColLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lineColLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            indentLabel.leadingAnchor.constraint(equalTo: lineColLabel.trailingAnchor, constant: 20),
            indentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            diagnosticLabel.leadingAnchor.constraint(equalTo: indentLabel.trailingAnchor, constant: 20),
            diagnosticLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            encodingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            encodingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            lineEndingLabel.trailingAnchor.constraint(equalTo: encodingLabel.leadingAnchor, constant: -12),
            lineEndingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            branchLabel.trailingAnchor.constraint(equalTo: fileTypeLabel.leadingAnchor, constant: -12),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            fileTypeLabel.trailingAnchor.constraint(equalTo: lineEndingLabel.leadingAnchor, constant: -12),
            fileTypeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(line: Int, column: Int, totalLines: Int, fileExtension: String?, selectionLength: Int = 0, detectedTabWidth: Int? = nil, detectedUseTabs: Bool? = nil) {
        if selectionLength > 0 {
            lineColLabel.stringValue = "Ln \(line), Col \(column)  (\(Self.formatCount(selectionLength)) sel)"
        } else {
            lineColLabel.stringValue = "Ln \(line), Col \(column)  (\(Self.formatCount(totalLines)) lines)"
        }

        if let useTabs = detectedUseTabs, useTabs {
            indentLabel.stringValue = "Tab Size: \(Preferences.shared.tabWidth)"
        } else {
            let width = detectedTabWidth ?? Preferences.shared.tabWidth
            indentLabel.stringValue = "Spaces: \(width)"
        }

        if let ext = fileExtension, !ext.isEmpty {
            fileTypeLabel.stringValue = languageName(for: ext)
        } else {
            fileTypeLabel.stringValue = "Plain Text"
        }
    }

    func updateLineEnding(_ text: String) {
        if text.contains("\r\n") {
            lineEndingLabel.stringValue = "CRLF"
        } else {
            lineEndingLabel.stringValue = "LF"
        }
    }

    func setLineEnding(_ ending: String) {
        lineEndingLabel.stringValue = ending
    }

    func updateDiagnosticCount(errors: Int, warnings: Int) {
        if errors == 0 && warnings == 0 {
            diagnosticLabel.stringValue = ""
        } else {
            var parts: [String] = []
            if errors > 0 { parts.append("\u{26D4} \(errors)") }
            if warnings > 0 { parts.append("\u{26A0}\u{FE0F} \(warnings)") }
            diagnosticLabel.stringValue = parts.joined(separator: "  ")
            diagnosticLabel.textColor = errors > 0
                ? NSColor(red: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
                : NSColor(red: 0.90, green: 0.80, blue: 0.30, alpha: 1.0)
        }
    }

    func updateBranch(_ branchName: String?) {
        if let branch = branchName, !branch.isEmpty {
            branchLabel.stringValue = "\u{2387} \(branch)"
        } else {
            branchLabel.stringValue = ""
        }
    }

    private func languageName(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "Swift"
        case "json": return "JSON"
        case "md", "markdown": return "Markdown"
        case "py": return "Python"
        case "js", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "scss": return "SCSS"
        case "yml", "yaml": return "YAML"
        case "xml": return "XML"
        case "sh", "bash": return "Shell"
        case "zsh": return "Zsh"
        case "rb": return "Ruby"
        case "go": return "Go"
        case "rs": return "Rust"
        case "c": return "C"
        case "cpp", "cc", "cxx": return "C++"
        case "h", "hpp": return "Header"
        case "m": return "Objective-C"
        case "mm": return "Objective-C++"
        case "toml": return "TOML"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "plist": return "Plist"
        case "txt": return "Plain Text"
        case "log": return "Log"
        default: return ext.uppercased()
        }
    }

    /// Format a count for compact display: 1234 → "1,234", 1234567 → "1.2M"
    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.1fM", m)
        } else if n >= 10_000 {
            let k = Double(n) / 1000
            return String(format: "%.1fK", k)
        } else {
            return "\(n)"
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        dirtyRect.fill()
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
