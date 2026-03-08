import AppKit

/// Settings window for editor preferences.
class PreferencesWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let vc = PreferencesViewController()
        window.contentViewController = vc
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

class PreferencesViewController: NSViewController {

    private let prefs = Preferences.shared

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0).cgColor

        let titleLabel = makeLabel("Editor", bold: true, size: 15)
        titleLabel.frame = NSRect(x: 20, y: 296, width: 200, height: 20)
        container.addSubview(titleLabel)

        // Font size
        let fontLabel = makeLabel("Font Size:")
        fontLabel.frame = NSRect(x: 20, y: 258, width: 140, height: 20)
        container.addSubview(fontLabel)

        let fontStepper = NSStepper()
        fontStepper.minValue = 8
        fontStepper.maxValue = 32
        fontStepper.increment = 1
        fontStepper.integerValue = Int(prefs.fontSize)
        fontStepper.target = self
        fontStepper.action = #selector(fontSizeChanged(_:))
        fontStepper.frame = NSRect(x: 220, y: 258, width: 20, height: 20)
        container.addSubview(fontStepper)

        let fontValueLabel = makeLabel("\(Int(prefs.fontSize)) pt")
        fontValueLabel.frame = NSRect(x: 170, y: 258, width: 50, height: 20)
        fontValueLabel.tag = 100
        container.addSubview(fontValueLabel)

        // Tab width
        let tabLabel = makeLabel("Tab Width:")
        tabLabel.frame = NSRect(x: 20, y: 224, width: 140, height: 20)
        container.addSubview(tabLabel)

        let tabPopup = NSPopUpButton(frame: NSRect(x: 170, y: 220, width: 80, height: 28))
        tabPopup.addItems(withTitles: ["2", "4", "8"])
        tabPopup.selectItem(withTitle: "\(prefs.tabWidth)")
        tabPopup.target = self
        tabPopup.action = #selector(tabWidthChanged(_:))
        container.addSubview(tabPopup)

        // Separator
        let sep1 = makeSeparator(y: 208)
        container.addSubview(sep1)

        let viewTitle = makeLabel("View", bold: true, size: 15)
        viewTitle.frame = NSRect(x: 20, y: 180, width: 200, height: 20)
        container.addSubview(viewTitle)

        // Show minimap
        let minimapCheck = NSButton(checkboxWithTitle: "Show Minimap", target: self, action: #selector(minimapToggled(_:)))
        minimapCheck.state = prefs.showMinimap ? .on : .off
        minimapCheck.frame = NSRect(x: 20, y: 150, width: 200, height: 20)
        container.addSubview(minimapCheck)

        // Show indent guides
        let guidesCheck = NSButton(checkboxWithTitle: "Show Indent Guides", target: self, action: #selector(indentGuidesToggled(_:)))
        guidesCheck.state = prefs.showIndentGuides ? .on : .off
        guidesCheck.frame = NSRect(x: 20, y: 122, width: 200, height: 20)
        container.addSubview(guidesCheck)

        // Separator
        let sep2 = makeSeparator(y: 108)
        container.addSubview(sep2)

        let saveTitle = makeLabel("Saving", bold: true, size: 15)
        saveTitle.frame = NSRect(x: 20, y: 80, width: 200, height: 20)
        container.addSubview(saveTitle)

        // Trim trailing whitespace
        let trimCheck = NSButton(checkboxWithTitle: "Trim Trailing Whitespace on Save", target: self, action: #selector(trimToggled(_:)))
        trimCheck.state = prefs.trimTrailingWhitespace ? .on : .off
        trimCheck.frame = NSRect(x: 20, y: 50, width: 280, height: 20)
        container.addSubview(trimCheck)

        // Ensure trailing newline
        let newlineCheck = NSButton(checkboxWithTitle: "Ensure Trailing Newline on Save", target: self, action: #selector(newlineToggled(_:)))
        newlineCheck.state = prefs.ensureTrailingNewline ? .on : .off
        newlineCheck.frame = NSRect(x: 20, y: 22, width: 280, height: 20)
        container.addSubview(newlineCheck)

        self.view = container
    }

    // MARK: - Actions

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        prefs.fontSize = CGFloat(sender.integerValue)
        if let label = view.viewWithTag(100) as? NSTextField {
            label.stringValue = "\(sender.integerValue) pt"
        }
    }

    @objc private func tabWidthChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let width = Int(title) {
            prefs.tabWidth = width
        }
    }

    @objc private func minimapToggled(_ sender: NSButton) {
        prefs.showMinimap = sender.state == .on
    }

    @objc private func indentGuidesToggled(_ sender: NSButton) {
        prefs.showIndentGuides = sender.state == .on
    }

    @objc private func trimToggled(_ sender: NSButton) {
        prefs.trimTrailingWhitespace = sender.state == .on
    }

    @objc private func newlineToggled(_ sender: NSButton) {
        prefs.ensureTrailingNewline = sender.state == .on
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        return label
    }

    private func makeSeparator(y: CGFloat) -> NSView {
        let sep = NSView(frame: NSRect(x: 20, y: y, width: 380, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.30, alpha: 1.0).cgColor
        return sep
    }
}
