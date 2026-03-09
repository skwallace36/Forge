import Foundation

/// Manages JSON-RPC communication over stdin/stdout with an LSP server process.
class JSONRPCConnection {

    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var notificationHandler: ((String, [String: Any]) -> Void)?
    private var readBuffer = Data()
    private let queue = DispatchQueue(label: "forge.jsonrpc", qos: .userInitiated)

    /// Called when the LSP process terminates unexpectedly
    var onTermination: (() -> Void)?

    var onNotification: ((String, [String: Any]) -> Void)? {
        get { notificationHandler }
        set { notificationHandler = newValue }
    }

    var isRunning: Bool {
        process.isRunning
    }

    init(executablePath: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.process = Process()
        self.stdin = Pipe()
        self.stdout = Pipe()
        self.stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }
    }

    func start() throws {
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.onTermination?()
            }
        }
        try process.run()
        startReading()
    }

    func stop() {
        process.terminate()
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: LSPError.connectionClosed)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Send Request (async)

    func sendRequest(method: String, params: Any?, timeout: TimeInterval = 30) async throws -> JSONRPCResponse {
        let id = nextRequestID
        nextRequestID += 1

        let request = JSONRPCRequest(
            id: id,
            method: method,
            params: params.map { AnyCodable($0) }
        )

        let data = try JSONEncoder().encode(request)

        // Store continuation BEFORE sending the message to avoid a race where
        // the response arrives before the continuation is registered.
        let response: JSONRPCResponse = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pendingRequests[id] = continuation
                self.sendMessage(data)
            }

            // Schedule a timeout that cancels the pending request
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.queue.async {
                    if let cont = self?.pendingRequests.removeValue(forKey: id) {
                        cont.resume(throwing: LSPError.timeout(method))
                    }
                }
            }
        }
        return response
    }

    // MARK: - Send Notification (fire-and-forget)

    func sendNotification(method: String, params: Any?) {
        let notification = JSONRPCNotification(
            method: method,
            params: params.map { AnyCodable($0) }
        )

        guard let data = try? JSONEncoder().encode(notification) else { return }
        sendMessage(data)
    }

    // MARK: - Message Framing

    private func sendMessage(_ data: Data) {
        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }

        let fileHandle = stdin.fileHandleForWriting
        fileHandle.write(headerData)
        fileHandle.write(data)
    }

    // MARK: - Reading

    private func startReading() {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.readBuffer.append(data)
                self?.processBuffer()
            }
        }
    }

    private func processBuffer() {
        while true {
            // Look for Content-Length header
            guard let headerRange = readBuffer.range(of: Data("\r\n\r\n".utf8)) else { break }

            let headerData = readBuffer[readBuffer.startIndex..<headerRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8),
                  let contentLength = parseContentLength(headerString) else {
                break
            }

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + contentLength

            guard readBuffer.count >= bodyEnd else { break }

            let bodyData = readBuffer[bodyStart..<bodyEnd]
            readBuffer = Data(readBuffer[bodyEnd...])

            handleMessage(Data(bodyData))
        }
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func handleMessage(_ data: Data) {
        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
            // Might be a notification from the server
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let method = json["method"] as? String {
                let params = json["params"] as? [String: Any] ?? [:]
                DispatchQueue.main.async { [weak self] in
                    self?.notificationHandler?(method, params)
                }
            }
            return
        }

        if let id = response.id, let continuation = pendingRequests.removeValue(forKey: id) {
            if let error = response.error {
                continuation.resume(throwing: LSPError.serverError(error.message))
            } else {
                continuation.resume(returning: response)
            }
        }
    }

    deinit {
        stop()
    }
}

enum LSPError: Error {
    case connectionClosed
    case serverError(String)
    case invalidResponse
    case timeout(String)
}
