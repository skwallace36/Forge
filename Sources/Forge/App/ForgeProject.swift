import AppKit

class ForgeProject {

    let rootURL: URL
    var openDocuments: [URL: ForgeDocument] = [:]
    let tabManager = TabManager()
    let lspClient: LSPClient
    let navigationHistory = NavigationHistory()
    let buildSystem: BuildSystem

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.lspClient = LSPClient(rootURL: rootURL)
        self.buildSystem = BuildSystem(projectRoot: rootURL)

        // Start LSP in background
        Task {
            do {
                try await lspClient.start()
            } catch {
                print("LSP failed to start: \(error)")
            }
        }
    }

    /// Open or return existing document for a URL
    func document(for url: URL) -> ForgeDocument {
        if let existing = openDocuments[url] {
            return existing
        }
        let doc = ForgeDocument(url: url)
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
