import AppKit
import SwiftTerm

/// Terminal emulator view for the bottom panel, powered by SwiftTerm.
class TerminalPanelView: NSView, LocalProcessTerminalViewDelegate {

    private let terminalView: LocalProcessTerminalView
    private var projectRoot: URL?
    private var hasLaunched = false

    override init(frame: NSRect) {
        terminalView = LocalProcessTerminalView(frame: .zero)
        super.init(frame: frame)
        setupTerminal()
    }

    required init?(coder: NSCoder) {
        terminalView = LocalProcessTerminalView(frame: .zero)
        super.init(coder: coder)
        setupTerminal()
    }

    private func setupTerminal() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Terminal appearance
        terminalView.nativeForegroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        terminalView.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func setProjectRoot(_ url: URL) {
        self.projectRoot = url
    }

    /// Launch a shell in the project directory
    func launchShell() {
        guard !hasLaunched else { return }
        hasLaunched = true

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = projectRoot?.path ?? FileManager.default.currentDirectoryPath

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            execName: nil
        )

        // Send a cd command to navigate to the project directory
        let escapedDir = dir.replacingOccurrences(of: "'", with: "'\\''")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.terminalView.send(txt: "cd '\(escapedDir)' && clear\n")
        }
    }

    /// Launch Claude Code in the project directory
    func launchClaude() {
        guard !hasLaunched else { return }
        hasLaunched = true

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = projectRoot?.path ?? FileManager.default.currentDirectoryPath

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            execName: nil
        )

        // Navigate to project dir and launch claude
        let escapedDir = dir.replacingOccurrences(of: "'", with: "'\\''")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.terminalView.send(txt: "cd '\(escapedDir)' && clear && claude\n")
        }
    }

    /// Send text to the terminal
    func sendText(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Send code to Claude with file context
    func sendCodeToClaude(_ code: String, fileName: String?, line: Int?) {
        launchClaude()
        var prompt = ""
        if let fileName = fileName {
            prompt += "# From \(fileName)"
            if let line = line { prompt += ":\(line)" }
            prompt += "\n"
        }
        prompt += code
        // Escape the text for terminal input
        let escaped = prompt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        sendText(escaped)
    }

    /// Focus the terminal for input
    func focus() {
        window?.makeFirstResponder(terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal resized — nothing extra needed
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update tab title if we wanted
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Track directory changes if needed
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasLaunched = false
        // Could show a "process ended" message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.terminalView.feed(text: "\r\n[Process completed]\r\n")
        }
    }
}
