import AppKit

/// Bottom panel — placeholder for Claude terminal, build log, search results.
class BottomPanelViewController: NSViewController {

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor

        // Tab selector at top
        let segmented = NSSegmentedControl(labels: ["Claude", "Terminal", "Build Log", "Search"], trackingMode: .selectOne, target: nil, action: nil)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegment = 0
        segmented.segmentStyle = .texturedSquare
        container.addSubview(segmented)

        // Placeholder content
        let label = NSTextField(labelWithString: "Bottom panel — Claude integration coming soon")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(white: 0.5, alpha: 1.0)
        label.alignment = .center
        container.addSubview(label)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }
}
