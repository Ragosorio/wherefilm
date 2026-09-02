import Foundation

/// Caps how many full-resolution stills are being decoded at once.
///
/// This is the one step whose memory is decided by the camera that took the
/// picture rather than by anything WhereFilm chooses. ImageIO has to materialise
/// the whole image before it can hand back a 1024 px thumbnail, so a
/// 12-megapixel photograph transiently occupies about 48 MB — briefly, but a
/// dozen workers doing it together is 500 MB of spike.
///
/// It is deliberately *not* charged against `WorkBudget`. That budget measures
/// what a job **holds** for its whole life, and a still holds one keyframe.
/// Charging it the decode spike instead was measured at five times slower —
/// a 12-megapixel file priced at eleven frames leaves a 20-frame budget room for
/// exactly one photo at a time, which serialises the entire queue to save memory
/// nobody was short of. Bounding the spike where it happens costs nothing
/// measurable and keeps peak usage in line with the old, slower build.
public actor DecodeGate {
    /// Enough to keep the disk and the JPEG decoder busy, few enough that the
    /// spike stays bounded on a 16 GB machine.
    public static var recommendedLimit: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 3))
    }

    private let limit: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var nextWaiter = 0

    public init(limit: Int? = nil) {
        self.limit = max(1, limit ?? Self.recommendedLimit)
    }

    public var capacity: Int { limit }

    /// Runs `body` holding a slot. `body` is synchronous because CGImageSource
    /// is: the point is to bound how many such blocking decodes overlap.
    public func run<T: Sendable>(_ body: @Sendable () throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try body()
    }

    private func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if nextWaiter >= waiting.count {
            waiting.removeAll(keepingCapacity: true)
            nextWaiter = 0
            inFlight -= 1
        } else {
            let continuation = waiting[nextWaiter]
            nextWaiter += 1
            continuation.resume()
        }
    }
}
