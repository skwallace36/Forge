import AppKit

class ForgeProject {

    let rootURL: URL
    var openDocuments: [URL: ForgeDocument] = [:]
    let tabManager = TabManager()
    let lspClient: LSPClient
    let navigationHistory = NavigationHistory()
    let buildSystem: BuildSystem
    let gitStatus: GitStatusTracker

    /// Recently opened file URLs, most recent first. Used by Open Quickly.
    private(set) var recentFileURLs: [URL] = []
    private let maxRecentFiles = 20

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.lspClient = LSPClient(rootURL: rootURL)
        self.buildSystem = BuildSystem(projectRoot: rootURL)
        self.gitStatus = GitStatusTracker(rootURL: rootURL)

        // Clean up when a tab is closed
        tabManager.onTabClosed = { [weak self] url in
            self?.closeDocument(for: url)
        }

        // Re-open documents with LSP after a crash restart
        lspClient.onRestarted = { [weak self] in
            guard let self = self else { return }
            for (url, doc) in self.openDocuments {
                guard let lang = LSPClient.languageId(for: url) else { continue }
                self.lspClient.didOpen(url: url, text: doc.textStorage.string, language: lang)
            }
        }

        // Start LSP in background
        Task {
            do {
                try await lspClient.start()
            } catch {
                NSLog("LSP failed to start: \(error)")
            }
        }
    }

    /// Open or return existing document for a URL
    func document(for url: URL) -> ForgeDocument {
        if let existing = openDocuments[url] {
            return existing
        }
        let doc = ForgeDocument(url: url)
        doc.projectRoot = rootURL
        doc.reloadIndentSettings()
        openDocuments[url] = doc

        // Notify LSP for supported languages
        if let lang = LSPClient.languageId(for: url) {
            lspClient.didOpen(url: url, text: doc.textStorage.string, language: lang)
        }

        return doc
    }

    /// Close a document
    func closeDocument(for url: URL) {
        openDocuments.removeValue(forKey: url)
        if LSPClient.languageId(for: url) != nil {
            lspClient.didClose(url: url)
        }
    }

    /// Track a file as recently opened (moves to front if already present)
    func noteRecentFile(_ url: URL) {
        recentFileURLs.removeAll { $0 == url }
        recentFileURLs.insert(url, at: 0)
        if recentFileURLs.count > maxRecentFiles {
            recentFileURLs.removeLast()
        }
    }

    var displayName: String {
        rootURL.lastPathComponent
    }
}
