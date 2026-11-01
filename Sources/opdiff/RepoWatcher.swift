import CoreServices
import Foundation

/// FSEvents on the repository folder (file-level events), delivered on a background queue.
final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(list)
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
