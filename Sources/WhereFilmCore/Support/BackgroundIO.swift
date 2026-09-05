import Darwin

/// Scope disk throttling to synchronous work on the current thread. Never hold
/// a thread policy across an await: Swift tasks can resume on another thread.
public enum BackgroundIO {
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        let changed = previous >= 0 && setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE) == 0
        defer {
            if changed { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, previous) }
        }
        return try body()
    }
}
