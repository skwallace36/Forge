import Foundation

/// Manages build operations by running `swift build` or `xcodebuild` as subprocesses.
class BuildSystem {

    enum ProjectType {
        case swiftPackage
        case xcodeProject(String)  // path to .xcodeproj
        case xcodeWorkspace(String)  // path to .xcworkspace
    }

    let projectRoot: URL
    private(set) var projectType: ProjectType
    private var currentProcess: Process?

    /// Called on the main thread with each line of build output.
    var onOutput: ((String) -> Void)?

    /// Called on the main thread when the build finishes. Bool is true for success.
    var onComplete: ((Bool) -> Void)?

    var isBuilding: Bool { currentProcess != nil }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.projectType = BuildSystem.detectProjectType(at: projectRoot)
    }

    private static func detectProjectType(at root: URL) -> ProjectType {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return .swiftPackage
        }

        // Prefer workspace over project, project over SPM
        for item in contents {
            if item.pathExtension == "xcworkspace" && !item.lastPathComponent.hasPrefix(".") {
                return .xcodeWorkspace(item.path)
            }
        }
        for item in contents {
            if item.pathExtension == "xcodeproj" {
                return .xcodeProject(item.path)
            }
        }

        // Check for Package.swift
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return .swiftPackage
        }

        return .swiftPackage
    }

    /// Run a build.
    func build() {
        guard !isBuilding else { return }

        switch projectType {
        case .swiftPackage:
            runCommand(executable: "/usr/bin/swift", args: ["build"])
        case .xcodeProject(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-project", path, "-scheme", guessScheme(path), "build"],
                       env: ["COMPILER_INDEX_STORE_ENABLE": "NO"])
        case .xcodeWorkspace(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-workspace", path, "-scheme", guessScheme(path), "build"],
                       env: ["COMPILER_INDEX_STORE_ENABLE": "NO"])
        }
    }

    /// Build and then run the product.
    func buildAndRun() {
        guard !isBuilding else { return }

        switch projectType {
        case .swiftPackage:
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
        case .xcodeProject(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-project", path, "-scheme", guessScheme(path), "build"],
                       env: ["COMPILER_INDEX_STORE_ENABLE": "NO"])
        case .xcodeWorkspace(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-workspace", path, "-scheme", guessScheme(path), "build"],
                       env: ["COMPILER_INDEX_STORE_ENABLE": "NO"])
        }
    }

    /// Run the built product (SPM only).
    func run() {
        guard !isBuilding else { return }
        runCommand(executable: "/usr/bin/swift", args: ["run"])
    }

    /// Clean build artifacts.
    func clean() {
        guard !isBuilding else { return }

        switch projectType {
        case .swiftPackage:
            runCommand(executable: "/usr/bin/swift", args: ["package", "clean"])
        case .xcodeProject(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-project", path, "-scheme", guessScheme(path), "clean"])
        case .xcodeWorkspace(let path):
            runCommand(executable: "/usr/bin/xcodebuild",
                       args: ["-workspace", path, "-scheme", guessScheme(path), "clean"])
        }
    }

    /// Cancel the current build or run.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - Private

    private func runCommand(executable: String, args: [String], env: [String: String]? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = projectRoot

        if let env = env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env { environment[key] = value }
            process.environment = environment
        }

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

        let cmdStr = ([executable] + args).joined(separator: " ")
        DispatchQueue.main.async {
            self.onOutput?("$ \(cmdStr)\n")
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.onOutput?("Failed to start: \(error.localizedDescription)\n")
                self.currentProcess = nil
                self.onComplete?(false)
            }
        }
    }

    /// Guess the scheme name from a project/workspace path.
    private func guessScheme(_ path: String) -> String {
        // Use the project/workspace name minus the extension
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name
    }
}
