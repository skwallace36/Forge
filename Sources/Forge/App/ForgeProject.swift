import AppKit

class ForgeProject {

    let rootURL: URL
    var openDocuments: [URL: ForgeDocument] = [:]
    let tabManager = TabManager()

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Open or return existing document for a URL
    func document(for url: URL) -> ForgeDocument {
        if let existing = openDocuments[url] {
            return existing
        }
        let doc = ForgeDocument(url: url)
        openDocuments[url] = doc
        return doc
    }

    /// Close a document
    func closeDocument(for url: URL) {
        openDocuments.removeValue(forKey: url)
    }

    var displayName: String {
        rootURL.lastPathComponent
    }
}
