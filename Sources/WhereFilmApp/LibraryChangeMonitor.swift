import Foundation
import CoreServices

/// Lightweight notification that something changed below a watched library.
///
/// FSEvents deliberately coalesces changes. WhereFilm does not need to mirror a
/// filesystem journal or trust an event path as canonical; it only needs a
/// wake-up signal. The subsequent incremental scan is the source of truth and,
/// because unchanged files take the metadata-only fast path, it never re-opens
/// multi-gigabyte media just to notice one rename.
final class LibraryChangeMonitor: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let paths: [String]
    private let callbackBox: CallbackBox
    private let queue = DispatchQueue(label: "com.wherefilm.library-events", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [URL], onChange: @escaping @Sendable () -> Void) {
        self.paths = Array(Set(paths.map { $0.standardizedFileURL.path })).sorted()
        callbackBox = CallbackBox(onChange: onChange)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        guard !paths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, eventCount, _, _, _ in
            guard eventCount > 0, let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)

        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            flags)
        else { return false }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
