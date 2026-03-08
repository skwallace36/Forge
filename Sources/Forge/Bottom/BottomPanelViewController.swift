import AppKit

/// Bottom panel — build log, terminal, search results.
class BottomPanelViewController: NSViewController {

    private var segmented: NSSegmentedControl!
    private let buildLogView = BuildLogView()
    private(set) var searchResultsView = SearchResultsView()
    private var currentPanelIndex = 0

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor

        // Tab selector at top
        segmented = NSSegmentedControl(labels: ["Build Log", "Search"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegment = 0
        segmented.segmentStyle = .texturedSquare
        container.addSubview(segmented)

        // Top divider
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        container.addSubview(divider)

        // Build log
        buildLogView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buildLogView)

        // Search results
        searchResultsView.translatesAutoresizingMaskIntoConstraints = false
        searchResultsView.isHidden = true
        container.addSubview(searchResultsView)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            segmented.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            buildLogView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            buildLogView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buildLogView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buildLogView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchResultsView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            searchResultsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchResultsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchResultsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        showPanel(at: sender.selectedSegment)
    }

    private func showPanel(at index: Int) {
        currentPanelIndex = index
        buildLogView.isHidden = index != 0
        searchResultsView.isHidden = index != 1
    }

    func showSearch() {
        segmented.selectedSegment = 1
        showPanel(at: 1)
        searchResultsView.focusSearchField()
    }

    func showBuildLog() {
        segmented.selectedSegment = 0
        showPanel(at: 0)
    }

    func appendBuildOutput(_ text: String) {
        buildLogView.append(text)
    }

    func clearBuildLog() {
        buildLogView.clear()
    }
}

/// Scrollable text view for build output.
class BuildLogView: NSView {

    private let scrollView: NSScrollView
    private let textView: NSTextView

    private let bgColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
    private let textColor = NSColor(white: 0.75, alpha: 1.0)
    private let errorColor = NSColor(red: 0.99, green: 0.35, blue: 0.35, alpha: 1.0)
    private let warningColor = NSColor(red: 0.99, green: 0.80, blue: 0.28, alpha: 1.0)
    private let successColor = NSColor(red: 0.40, green: 0.85, blue: 0.40, alpha: 1.0)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: NSRect) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView

        self.scrollView = sv
        self.textView = tv
        super.init(frame: frame)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = bgColor
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = bgColor

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func append(_ text: String) {
        let attrs = attributesForLine(text)
        let attrStr = NSAttributedString(string: text, attributes: attrs)

        textView.textStorage?.append(attrStr)
        textView.scrollToEndOfDocument(nil)
    }

    func clear() {
        textView.string = ""
    }

    private func attributesForLine(_ line: String) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        if line.contains("error:") || line.contains("Error:") {
            color = errorColor
        } else if line.contains("warning:") || line.contains("Warning:") {
            color = warningColor
        } else if line.contains("Build complete") {
            color = successColor
        } else {
            color = textColor
        }
        return [
            .foregroundColor: color,
            .font: font,
        ]
    }
}
