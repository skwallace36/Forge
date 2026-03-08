import AppKit

/// SourceKit-LSP client — manages the LSP subprocess and provides language intelligence.
class LSPClient {

    private var connection: JSONRPCConnection?
    private let rootURL: URL
    private var initialized = false
    private var openDocumentVersions: [URL: Int] = [:]
    private var isRestarting = false

    /// Callback for diagnostics published by the server
    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?

    /// Called when LSP restarts so the editor can re-open documents
    var onRestarted: (() -> Void)?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Find sourcekit-lsp
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["--find", "sourcekit-lsp"]
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw LSPError.serverError("Could not find sourcekit-lsp")
        }

        let conn = JSONRPCConnection(executablePath: path)

        // Handle server notifications
        conn.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }

        // Handle unexpected termination
        conn.onTermination = { [weak self] in
            self?.handleCrash()
        }

        try conn.start()
        self.connection = conn

        // Send initialize
        let initParams: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURL.absoluteString,
            "capabilities": [
                "textDocument": [
                    "completion": [
                        "completionItem": ["snippetSupport": false],
                    ],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "publishDiagnostics": ["relatedInformation": true],
                    "definition": [:] as [String: Any],
                    "references": [:] as [String: Any],
                    "documentSymbol": [:] as [String: Any],
                    "codeAction": [
                        "codeActionLiteralSupport": [
                            "codeActionKind": [
                                "valueSet": ["quickfix", "refactor", "source"],
                            ],
                        ],
                    ] as [String: Any],
                    "formatting": [:] as [String: Any],
                    "signatureHelp": [
                        "signatureInformation": [
                            "parameterInformation": ["labelOffsetSupport": true],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]

        _ = try await conn.sendRequest(method: "initialize", params: initParams)
        conn.sendNotification(method: "initialized", params: [:] as [String: Any])
        initialized = true
    }

    func stop() {
        initialized = false
        guard let conn = connection else { return }
        conn.onTermination = nil // prevent crash handler during intentional stop
        connection = nil

        // LSP spec: shutdown is a request, exit is a notification.
        // Send shutdown request and follow with exit; don't wait for response
        // since we may be called from deinit.
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try? await conn.sendRequest(method: "shutdown", params: nil)
                    conn.sendNotification(method: "exit", params: nil)
                }
                // Timeout after 2 seconds — don't hang forever
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                // Whichever finishes first
                await group.next()
                group.cancelAll()
            }
            conn.stop()
        }
    }

    // MARK: - Language Detection

    /// Map file extensions to LSP language identifiers.
    /// sourcekit-lsp supports Swift, C, C++, Objective-C, and Objective-C++.
    static func languageId(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "c": return "c"
        case "h": return "c"  // headers default to C; sourcekit-lsp infers if ObjC
        case "cpp", "cc", "cxx": return "cpp"
        case "hpp", "hxx": return "cpp"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        default: return nil
        }
    }

    // MARK: - Document Lifecycle

    func didOpen(url: URL, text: String, language: String = "swift") {
        guard initialized else { return }
        openDocumentVersions[url] = 1

        let params: [String: Any] = [
            "textDocument": [
                "uri": url.absoluteString,
                "languageId": language,
                "version": 1,
                "text": text,
            ] as [String: Any],
        ]
        connection?.sendNotification(method: "textDocument/didOpen", params: params)
    }

    func didChange(url: URL, text: String) {
        guard initialized else { return }
        let version = (openDocumentVersions[url] ?? 0) + 1
        openDocumentVersions[url] = version

        let params: [String: Any] = [
            "textDocument": [
                "uri": url.absoluteString,
                "version": version,
            ] as [String: Any],
            "contentChanges": [
                ["text": text],
            ],
        ]
        connection?.sendNotification(method: "textDocument/didChange", params: params)
    }

    func didSave(url: URL, text: String? = nil) {
        guard initialized else { return }
        var params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
        ]
        if let text = text {
            params["text"] = text
        }
        connection?.sendNotification(method: "textDocument/didSave", params: params)
    }

    func didClose(url: URL) {
        guard initialized else { return }
        openDocumentVersions.removeValue(forKey: url)

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
        ]
        connection?.sendNotification(method: "textDocument/didClose", params: params)
    }

    // MARK: - Completion

    func completion(url: URL, line: Int, character: Int) async throws -> [LSPCompletionItem] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]

        let response = try await conn.sendRequest(method: "textDocument/completion", params: params)
        return parseCompletionItems(from: response)
    }

    // MARK: - Definition

    func definition(url: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]

        let response = try await conn.sendRequest(method: "textDocument/definition", params: params)
        return parseLocations(from: response)
    }

    // MARK: - Hover

    func hover(url: URL, line: Int, character: Int) async throws -> String? {
        guard initialized, let conn = connection else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]

        let response = try await conn.sendRequest(method: "textDocument/hover", params: params)
        return parseHoverResult(from: response)
    }

    // MARK: - References

    func references(url: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
            "context": ["includeDeclaration": true],
        ]

        let response = try await conn.sendRequest(method: "textDocument/references", params: params)
        return parseLocations(from: response)
    }

    // MARK: - Rename

    func rename(url: URL, line: Int, character: Int, newName: String) async throws -> LSPWorkspaceEdit? {
        guard initialized, let conn = connection else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
            "newName": newName,
        ]

        let response = try await conn.sendRequest(method: "textDocument/rename", params: params)
        return parseWorkspaceEdit(from: response)
    }

    private func parseWorkspaceEdit(from response: JSONRPCResponse) -> LSPWorkspaceEdit? {
        guard let result = response.result?.value as? [String: Any],
              let changesDict = result["changes"] as? [String: [[String: Any]]] else {
            return nil
        }

        var changes: [URL: [LSPTextEdit]] = [:]
        for (uri, editsArray) in changesDict {
            guard let url = URL(string: uri) else { continue }
            let edits: [LSPTextEdit] = editsArray.compactMap { editDict in
                guard let rangeDict = editDict["range"] as? [String: Any],
                      let startDict = rangeDict["start"] as? [String: Any],
                      let endDict = rangeDict["end"] as? [String: Any],
                      let sl = startDict["line"] as? Int, let sc = startDict["character"] as? Int,
                      let el = endDict["line"] as? Int, let ec = endDict["character"] as? Int,
                      let newText = editDict["newText"] as? String else { return nil }
                return LSPTextEdit(
                    range: LSPRange(start: LSPPosition(line: sl, character: sc),
                                    end: LSPPosition(line: el, character: ec)),
                    newText: newText
                )
            }
            changes[url] = edits
        }

        return LSPWorkspaceEdit(changes: changes)
    }

    // MARK: - Signature Help

    func signatureHelp(url: URL, line: Int, character: Int) async throws -> LSPSignatureHelp? {
        guard initialized, let conn = connection else { return nil }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character],
        ]

        let response = try await conn.sendRequest(method: "textDocument/signatureHelp", params: params)
        return parseSignatureHelp(from: response)
    }

    private func parseSignatureHelp(from response: JSONRPCResponse) -> LSPSignatureHelp? {
        guard let result = response.result?.value as? [String: Any],
              let signatures = result["signatures"] as? [[String: Any]],
              !signatures.isEmpty else {
            return nil
        }

        let activeSignature = result["activeSignature"] as? Int ?? 0
        let activeParameter = result["activeParameter"] as? Int ?? 0

        let parsed: [LSPSignatureInformation] = signatures.compactMap { sig in
            guard let label = sig["label"] as? String else { return nil }
            let doc = sig["documentation"] as? String
                ?? (sig["documentation"] as? [String: Any])?["value"] as? String
            let params: [LSPParameterInformation]? = (sig["parameters"] as? [[String: Any]])?.compactMap { p in
                guard let label = p["label"] as? String else { return nil }
                let doc = p["documentation"] as? String
                    ?? (p["documentation"] as? [String: Any])?["value"] as? String
                return LSPParameterInformation(label: label, documentation: doc)
            }
            return LSPSignatureInformation(label: label, documentation: doc, parameters: params)
        }

        return LSPSignatureHelp(signatures: parsed, activeSignature: activeSignature, activeParameter: activeParameter)
    }

    // MARK: - Code Actions

    func codeActions(url: URL, range: LSPRange, diagnostics: [LSPDiagnostic] = []) async throws -> [LSPCodeAction] {
        guard initialized, let conn = connection else { return [] }

        let diagsArray: [[String: Any]] = diagnostics.map { diag in
            var d: [String: Any] = [
                "range": [
                    "start": ["line": diag.range.start.line, "character": diag.range.start.character],
                    "end": ["line": diag.range.end.line, "character": diag.range.end.character],
                ],
                "message": diag.message,
            ]
            if let severity = diag.severity { d["severity"] = severity }
            if let source = diag.source { d["source"] = source }
            return d
        }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "range": [
                "start": ["line": range.start.line, "character": range.start.character],
                "end": ["line": range.end.line, "character": range.end.character],
            ],
            "context": [
                "diagnostics": diagsArray,
            ] as [String: Any],
        ]

        let response = try await conn.sendRequest(method: "textDocument/codeAction", params: params)
        return parseCodeActions(from: response)
    }

    private func parseCodeActions(from response: JSONRPCResponse) -> [LSPCodeAction] {
        guard let result = response.result?.value as? [[String: Any]] else { return [] }
        return result.compactMap { LSPCodeAction.from($0) }
    }

    // MARK: - Formatting

    func formatDocument(url: URL, tabSize: Int = 4, insertSpaces: Bool = true) async throws -> [LSPTextEdit] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "options": [
                "tabSize": tabSize,
                "insertSpaces": insertSpaces,
            ],
        ]

        let response = try await conn.sendRequest(method: "textDocument/formatting", params: params)

        guard let editsArray = response.result?.value as? [[String: Any]] else { return [] }
        return editsArray.compactMap { LSPTextEdit.from($0) }
    }

    // MARK: - Document Symbols

    func documentSymbols(url: URL) async throws -> [LSPDocumentSymbol] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
        ]

        let response = try await conn.sendRequest(method: "textDocument/documentSymbol", params: params)
        return parseDocumentSymbols(from: response)
    }

    // MARK: - Workspace Symbol Search

    func workspaceSymbol(query: String) async throws -> [LSPSymbolInformation] {
        guard initialized, let conn = connection else { return [] }

        let params: [String: Any] = [
            "query": query,
        ]

        let response = try await conn.sendRequest(method: "workspace/symbol", params: params)
        return parseSymbolInformation(from: response)
    }

    private func parseSymbolInformation(from response: JSONRPCResponse) -> [LSPSymbolInformation] {
        guard let result = response.result?.value as? [[String: Any]] else { return [] }
        return result.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let kind = dict["kind"] as? Int,
                  let locationDict = dict["location"] as? [String: Any],
                  let uri = locationDict["uri"] as? String,
                  let rangeDict = locationDict["range"] as? [String: Any],
                  let startDict = rangeDict["start"] as? [String: Any],
                  let endDict = rangeDict["end"] as? [String: Any],
                  let sl = startDict["line"] as? Int, let sc = startDict["character"] as? Int,
                  let el = endDict["line"] as? Int, let ec = endDict["character"] as? Int else {
                return nil
            }
            let containerName = dict["containerName"] as? String
            return LSPSymbolInformation(
                name: name,
                kind: kind,
                containerName: containerName,
                location: LSPLocation(
                    uri: uri,
                    range: LSPRange(
                        start: LSPPosition(line: sl, character: sc),
                        end: LSPPosition(line: el, character: ec)
                    )
                )
            )
        }
    }

    // MARK: - Server Notifications

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"] as? String,
                  let url = URL(string: uri),
                  let diagnosticsArray = params["diagnostics"] as? [[String: Any]] else {
                return
            }

            let diagnostics: [LSPDiagnostic] = diagnosticsArray.compactMap { dict in
                guard let rangeDict = dict["range"] as? [String: Any],
                      let startDict = rangeDict["start"] as? [String: Any],
                      let endDict = rangeDict["end"] as? [String: Any],
                      let startLine = startDict["line"] as? Int,
                      let startChar = startDict["character"] as? Int,
                      let endLine = endDict["line"] as? Int,
                      let endChar = endDict["character"] as? Int,
                      let message = dict["message"] as? String else {
                    return nil
                }

                return LSPDiagnostic(
                    range: LSPRange(
                        start: LSPPosition(line: startLine, character: startChar),
                        end: LSPPosition(line: endLine, character: endChar)
                    ),
                    severity: dict["severity"] as? Int,
                    message: message,
                    source: dict["source"] as? String
                )
            }

            onDiagnostics?(url, diagnostics)

        default:
            break
        }
    }

    // MARK: - Response Parsing

    private func parseCompletionItems(from response: JSONRPCResponse) -> [LSPCompletionItem] {
        guard let result = response.result?.value else { return [] }

        // completionList or array of items
        let items: [[String: Any]]
        if let dict = result as? [String: Any], let list = dict["items"] as? [[String: Any]] {
            items = list
        } else if let array = result as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        return items.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let doc = item["documentation"] as? String
                ?? (item["documentation"] as? [String: Any])?["value"] as? String
            return LSPCompletionItem(
                label: label,
                kind: item["kind"] as? Int,
                detail: item["detail"] as? String,
                insertText: item["insertText"] as? String,
                documentation: doc
            )
        }
    }

    private func parseLocations(from response: JSONRPCResponse) -> [LSPLocation] {
        guard let result = response.result?.value else { return [] }

        let locationDicts: [[String: Any]]
        if let single = result as? [String: Any] {
            locationDicts = [single]
        } else if let array = result as? [[String: Any]] {
            locationDicts = array
        } else {
            return []
        }

        return locationDicts.compactMap { dict in
            guard let uri = dict["uri"] as? String,
                  let rangeDict = dict["range"] as? [String: Any],
                  let startDict = rangeDict["start"] as? [String: Any],
                  let endDict = rangeDict["end"] as? [String: Any],
                  let startLine = startDict["line"] as? Int,
                  let startChar = startDict["character"] as? Int,
                  let endLine = endDict["line"] as? Int,
                  let endChar = endDict["character"] as? Int else {
                return nil
            }

            return LSPLocation(
                uri: uri,
                range: LSPRange(
                    start: LSPPosition(line: startLine, character: startChar),
                    end: LSPPosition(line: endLine, character: endChar)
                )
            )
        }
    }

    private func parseHoverResult(from response: JSONRPCResponse) -> String? {
        guard let result = response.result?.value as? [String: Any],
              let contents = result["contents"] else {
            return nil
        }

        if let str = contents as? String {
            return str
        }
        if let dict = contents as? [String: Any], let value = dict["value"] as? String {
            return value
        }
        return nil
    }

    private func parseDocumentSymbols(from response: JSONRPCResponse) -> [LSPDocumentSymbol] {
        guard let result = response.result?.value as? [[String: Any]] else { return [] }

        func parseSymbol(_ dict: [String: Any]) -> LSPDocumentSymbol? {
            guard let name = dict["name"] as? String,
                  let kind = dict["kind"] as? Int,
                  let rangeDict = dict["range"] as? [String: Any],
                  let selRangeDict = dict["selectionRange"] as? [String: Any] else {
                return nil
            }

            func parseRange(_ d: [String: Any]) -> LSPRange? {
                guard let s = d["start"] as? [String: Any],
                      let e = d["end"] as? [String: Any],
                      let sl = s["line"] as? Int, let sc = s["character"] as? Int,
                      let el = e["line"] as? Int, let ec = e["character"] as? Int else {
                    return nil
                }
                return LSPRange(start: LSPPosition(line: sl, character: sc),
                                end: LSPPosition(line: el, character: ec))
            }

            guard let range = parseRange(rangeDict),
                  let selRange = parseRange(selRangeDict) else {
                return nil
            }

            let children = (dict["children"] as? [[String: Any]])?.compactMap(parseSymbol)
            return LSPDocumentSymbol(name: name, kind: kind, range: range, selectionRange: selRange, children: children)
        }

        return result.compactMap(parseSymbol)
    }

    // MARK: - Crash Recovery

    private func handleCrash() {
        guard initialized, !isRestarting else { return }
        initialized = false
        connection = nil

        NSLog("sourcekit-lsp crashed, restarting in 2 seconds...")

        isRestarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptRestart()
        }
    }

    private func attemptRestart() {
        Task {
            do {
                try await start()
                isRestarting = false
                NSLog("sourcekit-lsp restarted successfully")
                await MainActor.run {
                    onRestarted?()
                }
            } catch {
                isRestarting = false
                NSLog("sourcekit-lsp restart failed: \(error)")
            }
        }
    }

    deinit {
        stop()
    }
}
