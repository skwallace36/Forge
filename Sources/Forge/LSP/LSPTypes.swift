import Foundation

// MARK: - JSON-RPC

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: AnyCodable?
}

struct JSONRPCNotification: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: AnyCodable?
}

struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

/// Type-erased Codable wrapper for heterogeneous JSON.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - LSP Types

struct LSPPosition: Codable {
    let line: Int
    let character: Int
}

struct LSPRange: Codable {
    let start: LSPPosition
    let end: LSPPosition
}

struct LSPLocation: Codable {
    let uri: String
    let range: LSPRange
}

struct LSPTextDocumentIdentifier: Codable {
    let uri: String
}

struct LSPTextDocumentPositionParams: Codable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
}

struct LSPDiagnostic: Codable {
    let range: LSPRange
    let severity: Int?
    let message: String
    let source: String?

    enum Severity: Int {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }
}

struct LSPCompletionItem: Codable {
    let label: String
    let kind: Int?
    let detail: String?
    let insertText: String?
}

struct LSPHover: Codable {
    let contents: AnyCodable
}

struct LSPDocumentSymbol: Codable {
    let name: String
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [LSPDocumentSymbol]?
}

struct LSPTextEdit: Codable {
    let range: LSPRange
    let newText: String

    static func from(_ dict: [String: Any]) -> LSPTextEdit? {
        guard let rangeDict = dict["range"] as? [String: Any],
              let startDict = rangeDict["start"] as? [String: Any],
              let endDict = rangeDict["end"] as? [String: Any],
              let startLine = startDict["line"] as? Int,
              let startChar = startDict["character"] as? Int,
              let endLine = endDict["line"] as? Int,
              let endChar = endDict["character"] as? Int,
              let newText = dict["newText"] as? String else {
            return nil
        }
        return LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: startLine, character: startChar),
                end: LSPPosition(line: endLine, character: endChar)
            ),
            newText: newText
        )
    }
}

struct LSPWorkspaceEdit {
    let changes: [URL: [LSPTextEdit]]
}

struct LSPCodeAction {
    let title: String
    let kind: String?
    let edit: LSPWorkspaceEdit?
    let diagnostics: [LSPDiagnostic]?

    static func from(_ dict: [String: Any]) -> LSPCodeAction? {
        guard let title = dict["title"] as? String else { return nil }
        let kind = dict["kind"] as? String

        var edit: LSPWorkspaceEdit?
        if let editDict = dict["edit"] as? [String: Any],
           let changesDict = editDict["changes"] as? [String: [[String: Any]]] {
            var changes: [URL: [LSPTextEdit]] = [:]
            for (uri, editsArray) in changesDict {
                guard let url = URL(string: uri) else { continue }
                changes[url] = editsArray.compactMap { LSPTextEdit.from($0) }
            }
            edit = LSPWorkspaceEdit(changes: changes)
        }

        return LSPCodeAction(title: title, kind: kind, edit: edit, diagnostics: nil)
    }
}

struct LSPSignatureHelp {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int
    let activeParameter: Int
}

struct LSPSignatureInformation {
    let label: String
    let documentation: String?
    let parameters: [LSPParameterInformation]?
}

struct LSPParameterInformation {
    let label: String
    let documentation: String?
}

struct LSPSymbolInformation {
    let name: String
    let kind: Int
    let containerName: String?
    let location: LSPLocation

    var kindIcon: String {
        switch kind {
        case 1: return "F"   // File
        case 2: return "M"   // Module
        case 3: return "N"   // Namespace
        case 5: return "C"   // Class
        case 6: return "M"   // Method
        case 7: return "P"   // Property
        case 8: return "F"   // Field
        case 9: return "C"   // Constructor
        case 10: return "E"  // Enum
        case 11: return "I"  // Interface
        case 12: return "F"  // Function
        case 13: return "V"  // Variable
        case 23: return "S"  // Struct
        case 26: return "T"  // TypeParameter
        default: return "·"
        }
    }
}
