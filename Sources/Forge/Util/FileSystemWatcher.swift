import Foundation

/// Watches a directory tree for filesystem changes using FSEvents.
/// Debounces rapid changes to avoid thrashing.
class FileSystemWatcher {

    private var stream: FSEventStreamRef?
    private let path: String
    private let callback: ([String]) -> Void
    private let debounceInterval: TimeInterval

    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, debounceInterval: TimeInterval = 0.5, callback: @escaping ([String]) -> Void) {
        self.path = path
        self.debounceInterval = debounceInterval
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let eventStream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()

                var paths: [String] = []
                if let cfArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] {
                    paths = Array(cfArray.prefix(numEvents))
                }
                watcher.handleEvents(paths)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // latency in seconds
            flags
        ) else { return }

        self.stream = eventStream
        FSEventStreamSetDispatchQueue(eventStream, DispatchQueue.main)
        FSEventStreamStart(eventStream)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounceWorkItem?.cancel()
    }

    private func handleEvents(_ paths: [String]) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.callback(paths)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
