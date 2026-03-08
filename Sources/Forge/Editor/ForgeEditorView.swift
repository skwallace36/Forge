import AppKit

/// The main editor area: gutter + text view in a scroll view.
class ForgeEditorView: NSView {

    let scrollView = NSScrollView()
    let textView: ForgeTextView
    let gutterView = GutterView()

    private(set) var document: ForgeDocument?
    private var highlighter: SyntaxHighlighter?
    private var rehighlightWorkItem: DispatchWorkItem?

    let theme: Theme = .xcodeDefaultDark
    let fontSize: CGFloat = 13

    override init(frame frameRect: NSRect) {
        textView = ForgeTextView(frame: .zero)
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        textView = ForgeTextView(frame: .zero)
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Configure text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Editor font & colors from theme
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]

        // Text container sizing
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView

        // Gutter
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.theme = theme
        addSubview(gutterView)

        // Layout
        NSLayoutConstraint.activate([
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe text changes for gutter updates and re-highlighting
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe scroll for gutter sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Observe selection changes for current line highlight
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
    }

    func displayDocument(_ doc: ForgeDocument) {
        self.document = doc

        // Set text content (must set isRichText temporarily for attributed string)
        textView.isRichText = true
        textView.textStorage?.setAttributedString(doc.textStorage)

        // Re-apply base font/color
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = theme.foreground

        // Syntax highlighting
        if doc.fileExtension == "swift" {
            highlighter = SyntaxHighlighter(theme: theme, fontSize: fontSize)
            highlighter?.parse(doc.textStorage.string)
            if let ts = textView.textStorage {
                highlighter?.highlight(ts)
            }
        } else {
            highlighter = nil
        }

        // Back to rich text mode for highlighting
        textView.isRichText = true

        gutterView.textView = textView
        gutterView.needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        document?.isModified = true
        gutterView.needsDisplay = true

        // Debounced re-highlight (50ms)
        rehighlightWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rehighlight()
        }
        rehighlightWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        gutterView.needsDisplay = true
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        gutterView.needsDisplay = true
    }

    private func rehighlight() {
        guard let highlighter = highlighter, let ts = textView.textStorage else { return }
        let text = ts.string
        highlighter.parse(text)

        // Preserve selection
        let selectedRange = textView.selectedRange()
        highlighter.highlight(ts)
        textView.setSelectedRange(selectedRange)
    }
}
