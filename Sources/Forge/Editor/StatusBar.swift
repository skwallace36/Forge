import AppKit

/// Bottom status bar showing cursor position, file info, etc.
class StatusBar: NSView {

    private let lineColLabel = NSTextField(labelWithString: "Ln 1, Col 1")
    private let fileTypeLabel = NSTextField(labelWithString: "")
    private let encodingLabel = NSTextField(labelWithString: "UTF-8")
    private let indentLabel = NSTextField(labelWithString: "Spaces: 4")

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

        let labels = [lineColLabel, fileTypeLabel, encodingLabel, indentLabel]
        for label in labels {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = textColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            lineColLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lineColLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            indentLabel.leadingAnchor.constraint(equalTo: lineColLabel.trailingAnchor, constant: 20),
            indentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            encodingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            encodingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            fileTypeLabel.trailingAnchor.constraint(equalTo: encodingLabel.leadingAnchor, constant: -20),
            fileTypeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func update(line: Int, column: Int, totalLines: Int, fileExtension: String?) {
        lineColLabel.stringValue = "Ln \(line), Col \(column)  (\(totalLines) lines)"

        if let ext = fileExtension {
            fileTypeLabel.stringValue = languageName(for: ext)
        } else {
            fileTypeLabel.stringValue = ""
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
        case "plist": return "Plist"
        case "txt": return "Plain Text"
        case "log": return "Log"
        default: return ext.uppercased()
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
