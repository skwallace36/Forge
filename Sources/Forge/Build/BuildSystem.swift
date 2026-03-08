import Foundation

/// Manages build operations by running `swift build` or `xcodebuild` as subprocesses.
class BuildSystem {

    let projectRoot: URL
    private var currentProcess: Process?

    /// Called on the main thread with each line of build output.
    var onOutput: ((String) -> Void)?

    /// Called on the main thread when the build finishes. Bool is true for success.
    var onComplete: ((Bool) -> Void)?

    var isBuilding: Bool { currentProcess != nil }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Run `swift build` in the project root.
    func build() {
        guard !isBuilding else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build"]
        process.currentDirectoryURL = projectRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read output line by line
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onOutput?(text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.currentProcess = nil
                self?.onComplete?(proc.terminationStatus == 0)
            }
        }

        self.currentProcess = process

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.onOutput?("Failed to start build: \(error.localizedDescription)\n")
                self.currentProcess = nil
                self.onComplete?(false)
            }
        }
    }

    /// Build and then run the product.
    func buildAndRun() {
        guard !isBuilding else { return }

        // Save original callbacks
        let origOnComplete = onComplete
        onComplete = { [weak self] success in
            guard let self = self else { return }
            self.onComplete = origOnComplete
            if success {
                self.run()
            } else {
                origOnComplete?(false)
            }
        }
        build()
    }

    /// Run the built product.
    func run() {
        guard !isBuilding else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["run"]
        process.currentDirectoryURL = projectRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onOutput?(text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.currentProcess = nil
                self?.onComplete?(proc.terminationStatus == 0)
            }
        }

        self.currentProcess = process

        do {
            try process.run()
            DispatchQueue.main.async {
                self.onOutput?("Running...\n")
            }
        } catch {
            DispatchQueue.main.async {
                self.onOutput?("Failed to run: \(error.localizedDescription)\n")
                self.currentProcess = nil
                self.onComplete?(false)
            }
        }
    }

    /// Clean build artifacts.
    func clean() {
        guard !isBuilding else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["package", "clean"]
        process.currentDirectoryURL = projectRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onOutput?(text)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.currentProcess = nil
                self?.onComplete?(proc.terminationStatus == 0)
            }
        }

        self.currentProcess = process

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.onOutput?("Failed to clean: \(error.localizedDescription)\n")
                self.currentProcess = nil
                self.onComplete?(false)
            }
        }
    }

    /// Cancel the current build or run.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }
}
