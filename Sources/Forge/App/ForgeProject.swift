import AppKit

class ForgeProject {

    let rootURL: URL
    var openDocuments: [URL: ForgeDocument] = [:]
    let tabManager = TabManager()
    let lspClient: LSPClient
    let navigationHistory = NavigationHistory()
    let buildSystem: BuildSystem
    let gitStatus: GitStatusTracker

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.lspClient = LSPClient(rootURL: rootURL)
        self.buildSystem = BuildSystem(projectRoot: rootURL)
        self.gitStatus = GitStatusTracker(rootURL: rootURL)

        // Re-open documents with LSP after a crash restart
        lspClient.onRestarted = { [weak self] in
            guard let self = self else { return }
            for (url, doc) in self.openDocuments where url.pathExtension == "swift" {
                self.lspClient.didOpen(url: url, text: doc.textStorage.string)
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

        // Notify LSP
        if url.pathExtension == "swift" {
            lspClient.didOpen(url: url, text: doc.textStorage.string)
        }

        return doc
    }

    /// Close a document
    func closeDocument(for url: URL) {
        openDocuments.removeValue(forKey: url)
        lspClient.didClose(url: url)
    }

    var displayName: String {
        rootURL.lastPathComponent
    }
}
