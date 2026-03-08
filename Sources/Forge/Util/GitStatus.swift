import Foundation

/// Tracks git status for files in a project directory.
class GitStatusTracker {

    enum FileStatus {
        case modified       // M (modified, staged or unstaged)
        case added          // A (new file, staged)
        case untracked      // ? (untracked)
        case deleted        // D (deleted)
        case renamed        // R (renamed)
        case conflict       // U (unmerged/conflict)
    }

    private let rootURL: URL
    private var statusMap: [String: FileStatus] = [:]
    private var refreshWorkItem: DispatchWorkItem?

    private(set) var currentBranch: String?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Returns the git status for a file at the given URL, or nil if clean/not tracked
    func status(for url: URL) -> FileStatus? {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        return statusMap[relative]
    }

    /// Returns true if any file under this directory has changes
    func hasChanges(under url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let dirPath = url.standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath) else { return false }
        let relative = String(dirPath.dropFirst(rootPath.count + 1))

        return statusMap.keys.contains { key in
            key.hasPrefix(relative + "/") || key == relative
        }
    }

    /// Refresh git status asynchronously; calls completion on main thread when done
    func refresh(completion: (() -> Void)? = nil) {
        refreshWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let newMap = self.fetchGitStatus()
            let branch = self.fetchCurrentBranch()
            DispatchQueue.main.async {
                self.statusMap = newMap
                self.currentBranch = branch
                completion?()
            }
        }
        refreshWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func fetchGitStatus() -> [String: FileStatus] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["status", "--porcelain"]
        task.currentDirectoryURL = rootURL
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var map: [String: FileStatus] = [:]

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 4 else { continue }
            let index = line.index(line.startIndex, offsetBy: 0)
            let workTree = line.index(line.startIndex, offsetBy: 1)
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            let path = String(line[pathStart...])

            let x = line[index]
            let y = line[workTree]

            let status: FileStatus
            if x == "?" || y == "?" {
                status = .untracked
            } else if x == "A" {
                status = .added
            } else if x == "D" || y == "D" {
                status = .deleted
            } else if x == "R" {
                status = .renamed
            } else if x == "U" || y == "U" {
                status = .conflict
            } else {
                status = .modified
            }

            // Handle renamed files: "R  old -> new"
            if let arrowRange = path.range(of: " -> ") {
                let newPath = String(path[arrowRange.upperBound...])
                map[newPath] = status
            } else {
                map[path] = status
            }
        }

        return map
    }

    /// Returns changed line numbers for a specific file using `git diff`
    /// Result maps line numbers (0-based) to change type: "added" or "modified"
    func changedLines(for url: URL) -> [Int: String] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["diff", "--unified=0", "--no-color", "--", url.path]
        task.currentDirectoryURL = rootURL
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int: String] = [:]
        // Parse unified diff hunks: @@ -oldStart,oldCount +newStart,newCount @@
        let hunkPattern = try! NSRegularExpression(pattern: #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)

        for line in output.components(separatedBy: "\n") {
            let nsLine = line as NSString
            let matches = hunkPattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let newStart = Int(nsLine.substring(with: match.range(at: 3))) ?? 0
                let newCount = match.range(at: 4).location != NSNotFound
                    ? (Int(nsLine.substring(with: match.range(at: 4))) ?? 1)
                    : 1
                let oldCount = match.range(at: 2).location != NSNotFound
                    ? (Int(nsLine.substring(with: match.range(at: 2))) ?? 1)
                    : 1

                let changeType = oldCount == 0 ? "added" : "modified"
                for i in 0..<max(newCount, 1) {
                    result[newStart - 1 + i] = changeType // convert to 0-based
                }
            }
        }

        return result
    }

    /// Blame info for a single line
    struct BlameInfo {
        let author: String
        let date: String    // YYYY-MM-DD
        let summary: String
    }

    /// Returns blame info for each line (0-indexed) of the given file.
    /// Runs `git blame --porcelain` and parses the output.
    func blame(for url: URL) -> [Int: BlameInfo] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["blame", "--porcelain", "--", url.path]
        task.currentDirectoryURL = rootURL
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var result: [Int: BlameInfo] = [:]
        var currentAuthor = ""
        var currentDate = ""
        var currentSummary = ""
        var currentLine = -1

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty { continue }

            // Header line: <hash> <orig-line> <final-line> [<num-lines>]
            if line.count >= 40, !line.hasPrefix("\t"),
               let firstSpace = line.firstIndex(of: " "),
               line[line.startIndex..<firstSpace].allSatisfy({ $0.isHexDigit }) {
                let parts = line.split(separator: " ", maxSplits: 3)
                if parts.count >= 3, let finalLine = Int(parts[2]) {
                    currentLine = finalLine - 1 // convert to 0-based
                }
            } else if line.hasPrefix("author ") {
                currentAuthor = String(line.dropFirst(7))
            } else if line.hasPrefix("author-time ") {
                // Unix timestamp → YYYY-MM-DD
                if let timestamp = TimeInterval(line.dropFirst(12)) {
                    let date = Date(timeIntervalSince1970: timestamp)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    currentDate = formatter.string(from: date)
                }
            } else if line.hasPrefix("summary ") {
                currentSummary = String(line.dropFirst(8))
            } else if line.hasPrefix("\t") {
                // Content line marks end of a blame entry
                if currentLine >= 0 {
                    result[currentLine] = BlameInfo(
                        author: currentAuthor,
                        date: currentDate,
                        summary: currentSummary,
                    )
                }
            }
        }

        return result
    }

    private func fetchCurrentBranch() -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        task.currentDirectoryURL = rootURL
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
