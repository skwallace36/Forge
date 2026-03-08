import AppKit

/// Breadcrumb path bar above the editor — shows project > folder > file path.
class JumpBar: NSView {

    private var pathComponents: [String] = []
    private var labels: [NSTextField] = []
    private var separators: [NSTextField] = []

    let barHeight: CGFloat = 24
    private let backgroundColor = NSColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0)
    private let textColor = NSColor(white: 0.60, alpha: 1.0)
    private let activeTextColor = NSColor(white: 0.85, alpha: 1.0)
    private let separatorColor = NSColor(white: 0.35, alpha: 1.0)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    func update(fileURL: URL?, projectRoot: URL?) {
        // Clear old views
        labels.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        separators.removeAll()

        guard let fileURL = fileURL else {
            pathComponents = []
            return
        }

        // Build path components relative to project root
        if let root = projectRoot {
            let rootPath = root.path
            let filePath = fileURL.path
            if filePath.hasPrefix(rootPath) {
                let relativePath = String(filePath.dropFirst(rootPath.count + 1))
                pathComponents = [root.lastPathComponent] + relativePath.split(separator: "/").map(String.init)
            } else {
                pathComponents = Array(fileURL.pathComponents.suffix(3))
            }
        } else {
            pathComponents = [fileURL.lastPathComponent]
        }

        // Build UI
        var xOffset: CGFloat = 10

        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1

            // Separator (except before first)
            if index > 0 {
                let sep = makeLabel("›", color: separatorColor, bold: false)
                sep.frame.origin = NSPoint(x: xOffset, y: (barHeight - sep.frame.height) / 2)
                addSubview(sep)
                separators.append(sep)
                xOffset += sep.frame.width + 4
            }

            let label = makeLabel(component, color: isLast ? activeTextColor : textColor, bold: isLast)
            label.frame.origin = NSPoint(x: xOffset, y: (barHeight - label.frame.height) / 2)
            addSubview(label)
            labels.append(label)
            xOffset += label.frame.width + 4
        }
    }

    private func makeLabel(_ text: String, color: NSColor, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: bold ? .medium : .regular)
        label.textColor = color
        label.sizeToFit()
        return label
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        // Bottom border
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
