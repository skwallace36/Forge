import AppKit

/// Settings window for editor preferences.
class PreferencesWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 554),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 554))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0).cgColor

        var y: CGFloat = 520

        // Editor section
        let titleLabel = makeLabel("Editor", bold: true, size: 15)
        titleLabel.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(titleLabel)
        y -= 34

        // Font family
        let fontFamilyLabel = makeLabel("Font:")
        fontFamilyLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        container.addSubview(fontFamilyLabel)

        let fontPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 4, width: 200, height: 28))
        fontPopup.addItem(withTitle: "System Monospace")
        // Find monospaced fonts
        let monoFonts = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 13) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono") || family.localizedCaseInsensitiveContains("code") || family.localizedCaseInsensitiveContains("courier")
        }.sorted()
        for family in monoFonts {
            fontPopup.addItem(withTitle: family)
        }
        if let currentFont = prefs.fontName {
            fontPopup.selectItem(withTitle: currentFont)
        } else {
            fontPopup.selectItem(withTitle: "System Monospace")
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        container.addSubview(fontPopup)
        y -= 34

        // Font size
        let fontLabel = makeLabel("Font Size:")
        fontLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        container.addSubview(fontLabel)

        let fontValueLabel = makeLabel("\(Int(prefs.fontSize)) pt")
        fontValueLabel.frame = NSRect(x: 170, y: y, width: 50, height: 20)
        fontValueLabel.tag = 100
        container.addSubview(fontValueLabel)

        let fontStepper = NSStepper()
        fontStepper.minValue = 8
        fontStepper.maxValue = 32
        fontStepper.increment = 1
        fontStepper.integerValue = Int(prefs.fontSize)
        fontStepper.target = self
        fontStepper.action = #selector(fontSizeChanged(_:))
        fontStepper.frame = NSRect(x: 220, y: y, width: 20, height: 20)
        container.addSubview(fontStepper)
        y -= 34

        // Tab width
        let tabLabel = makeLabel("Tab Width:")
        tabLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        container.addSubview(tabLabel)

        let tabPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 4, width: 80, height: 28))
        tabPopup.addItems(withTitles: ["2", "4", "8"])
        tabPopup.selectItem(withTitle: "\(prefs.tabWidth)")
        tabPopup.target = self
        tabPopup.action = #selector(tabWidthChanged(_:))
        container.addSubview(tabPopup)
        y -= 40

        // Separator
        container.addSubview(makeSeparator(y: y))
        y -= 28

        // View section
        let viewTitle = makeLabel("View", bold: true, size: 15)
        viewTitle.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(viewTitle)
        y -= 30

        // Show minimap
        let minimapCheck = NSButton(checkboxWithTitle: "Show Minimap", target: self, action: #selector(minimapToggled(_:)))
        minimapCheck.state = prefs.showMinimap ? .on : .off
        minimapCheck.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(minimapCheck)
        y -= 28

        // Show indent guides
        let guidesCheck = NSButton(checkboxWithTitle: "Show Indent Guides", target: self, action: #selector(indentGuidesToggled(_:)))
        guidesCheck.state = prefs.showIndentGuides ? .on : .off
        guidesCheck.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(guidesCheck)
        y -= 28

        // Word wrap
        let wrapCheck = NSButton(checkboxWithTitle: "Word Wrap", target: self, action: #selector(wordWrapToggled(_:)))
        wrapCheck.state = prefs.wordWrap ? .on : .off
        wrapCheck.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(wrapCheck)
        y -= 28

        // Show invisible characters
        let invisiblesCheck = NSButton(checkboxWithTitle: "Show Invisible Characters", target: self, action: #selector(invisiblesToggled(_:)))
        invisiblesCheck.state = prefs.showInvisibles ? .on : .off
        invisiblesCheck.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        container.addSubview(invisiblesCheck)
        y -= 28

        // Bracket pair colorization
        let bracketCheck = NSButton(checkboxWithTitle: "Bracket Pair Colorization", target: self, action: #selector(bracketColorizationToggled(_:)))
        bracketCheck.state = prefs.bracketPairColorization ? .on : .off
        bracketCheck.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        container.addSubview(bracketCheck)
        y -= 28

        // Sticky scroll
        let stickyCheck = NSButton(checkboxWithTitle: "Sticky Scroll Headers", target: self, action: #selector(stickyScrollToggled(_:)))
        stickyCheck.state = prefs.stickyScroll ? .on : .off
        stickyCheck.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        container.addSubview(stickyCheck)
        y -= 28

        // Inline diagnostics
        let inlineDiagCheck = NSButton(checkboxWithTitle: "Inline Diagnostic Messages", target: self, action: #selector(inlineDiagnosticsToggled(_:)))
        inlineDiagCheck.state = prefs.inlineDiagnostics ? .on : .off
        inlineDiagCheck.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        container.addSubview(inlineDiagCheck)
        y -= 28

        // Hover tooltips
        let hoverCheck = NSButton(checkboxWithTitle: "Hover Tooltips (LSP)", target: self, action: #selector(hoverTooltipsToggled(_:)))
        hoverCheck.state = prefs.hoverTooltips ? .on : .off
        hoverCheck.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        container.addSubview(hoverCheck)
        y -= 30

        // Column ruler
        let rulerLabel = makeLabel("Column Ruler:")
        rulerLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        container.addSubview(rulerLabel)

        let rulerPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 4, width: 100, height: 28))
        rulerPopup.addItems(withTitles: ["Off", "80", "100", "120"])
        let currentRuler = prefs.columnRuler
        if currentRuler == 0 {
            rulerPopup.selectItem(withTitle: "Off")
        } else {
            rulerPopup.selectItem(withTitle: "\(currentRuler)")
        }
        rulerPopup.target = self
        rulerPopup.action = #selector(rulerChanged(_:))
        container.addSubview(rulerPopup)
        y -= 40

        // Separator
        container.addSubview(makeSeparator(y: y))
        y -= 28

        // Saving section
        let saveTitle = makeLabel("Saving", bold: true, size: 15)
        saveTitle.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        container.addSubview(saveTitle)
        y -= 30

        // Trim trailing whitespace
        let trimCheck = NSButton(checkboxWithTitle: "Trim Trailing Whitespace on Save", target: self, action: #selector(trimToggled(_:)))
        trimCheck.state = prefs.trimTrailingWhitespace ? .on : .off
        trimCheck.frame = NSRect(x: 20, y: y, width: 280, height: 20)
        container.addSubview(trimCheck)
        y -= 28

        // Ensure trailing newline
        let newlineCheck = NSButton(checkboxWithTitle: "Ensure Trailing Newline on Save", target: self, action: #selector(newlineToggled(_:)))
        newlineCheck.state = prefs.ensureTrailingNewline ? .on : .off
        newlineCheck.frame = NSRect(x: 20, y: y, width: 280, height: 20)
        container.addSubview(newlineCheck)

        self.view = container
    }

    // MARK: - Actions

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        if sender.selectedItem?.title == "System Monospace" {
            prefs.fontName = nil
        } else {
            prefs.fontName = sender.selectedItem?.title
        }
    }

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

    @objc private func wordWrapToggled(_ sender: NSButton) {
        prefs.wordWrap = sender.state == .on
    }

    @objc private func invisiblesToggled(_ sender: NSButton) {
        prefs.showInvisibles = sender.state == .on
    }

    @objc private func bracketColorizationToggled(_ sender: NSButton) {
        prefs.bracketPairColorization = sender.state == .on
    }

    @objc private func stickyScrollToggled(_ sender: NSButton) {
        prefs.stickyScroll = sender.state == .on
    }

    @objc private func inlineDiagnosticsToggled(_ sender: NSButton) {
        prefs.inlineDiagnostics = sender.state == .on
    }

    @objc private func hoverTooltipsToggled(_ sender: NSButton) {
        prefs.hoverTooltips = sender.state == .on
    }

    @objc private func rulerChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title {
            prefs.columnRuler = Int(title) ?? 0
        }
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
