import CoreServices
import Foundation

final class WorkspaceWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let onFileChanges: (([(URL, Int)]) -> Void)?
    private var fileChanges: [String: Int] = [:]
    private var pending: DispatchWorkItem?

    init?(url: URL, onFileChanges: (([(URL, Int)]) -> Void)? = nil, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.onFileChanges = onFileChanges
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            if watcher.onFileChanges != nil {
                let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
                for index in 0..<min(count, paths.count) {
                    let flag = flags[index]
                    let exists = FileManager.default.fileExists(atPath: paths[index])
                    let renamed = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
                    let created = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
                    watcher.fileChanges[paths[index]] = !exists ? 3 : (created || renamed ? 1 : 2)
                }
            }
            watcher.scheduleRefresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | (onFileChanges == nil ? 0 : kFSEventStreamCreateFlagFileEvents))) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changes = self.fileChanges.map { (URL(fileURLWithPath: $0.key), $0.value) }
            self.fileChanges.removeAll()
            self.onFileChanges?(changes)
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
