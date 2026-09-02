import Foundation

/// Bounds how much *decoded pixel data* the indexer may hold at once, measured
/// in keyframes rather than in jobs.
///
/// ## Why jobs are the wrong unit
///
/// The indexer used to run a single number of workers regardless of what they
/// were doing, and that number cannot be right for both kinds of work. Measured
/// on a 10-core M4, same machine, same build:
///
///     203 photographs (4032×3024)      4 workers → 20.5 s     8 workers → 12.0 s
///     18 min of 1080p across 6 reels   2 workers →  5.4 s     8 workers →  4.7 s
///                                                   286 MB              366 MB
///
/// Photos nearly halve with more workers; video barely moves and pays 80 MB for
/// it. The reason is that the two hold wildly different amounts of memory for
/// the same "one job": a photo job has a single decoded frame alive, while a
/// video job keeps a whole sampler batch — eight 1024 px frames plus the one
/// carried across the batch boundary — resident through Core ML *and* Vision.
///
/// So a video worker is worth about nine photo workers in memory and about one
/// in throughput. One global concurrency number has to pick a side, and whichever
/// it picks is wrong for half of a real library.
///
/// ## What this measures instead
///
/// Workers may run wide; what they may *hold* is capped. Light work (metadata,
/// hashing, a single photo) costs almost nothing and flows freely; a video pass
/// reserves its batch up front. The practical effect is that peak memory stops
/// depending on what happens to be in the queue — an archive of 4K stills and an
/// archive of three-hour masters converge on the same ceiling.
///
/// Admission is strictly first-in-first-out, so a video asking for nine frames
/// is never starved by an endless trickle of photos asking for one.
public actor WorkBudget {
    /// Frames the whole process may hold decoded at once.
    ///
    /// Sized so that the heaviest realistic mix — several video passes at their
    /// full sampler batch — stays inside the same envelope the app already
    /// occupied at the old, slower settings, while a photo-only library can put
    /// every Vision slot to work.
    public static var recommendedCapacity: Int {
        // Two full video batches in flight plus headroom for light work. Below
        // this videos serialise; above it memory grows with nothing to show for
        // it (measured: 8 video workers cost 80 MB more than 2 and saved 0.7 s).
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(12, min(32, cores * 2))
    }

    public static let shared = WorkBudget()

    private let capacity: Int
    private var used = 0

    private struct Waiter {
        let cost: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var queue: [Waiter] = []
    /// Cursor instead of `removeFirst`, so a long queue stays O(1) per wake.
    private var head = 0

    public init(capacity: Int? = nil) {
        self.capacity = max(1, capacity ?? Self.recommendedCapacity)
    }

    public var limit: Int { capacity }

    /// Runs `body` holding `cost` frames' worth of budget.
    ///
    /// A cost larger than the entire budget is clamped rather than rejected: one
    /// pathological asset should run alone and slowly, never deadlock.
    public func run<T: Sendable>(cost: Int, _ body: @Sendable () async throws -> T) async rethrows -> T {
        let want = min(max(1, cost), capacity)
        await acquire(want)
        defer { release(want) }
        return try await body()
    }

    private func acquire(_ cost: Int) async {
        // Jumping the queue when there happens to be room would let cheap work
        // overtake an already-waiting expensive job forever.
        if head == queue.count, used + cost <= capacity {
            used += cost
            return
        }
        await withCheckedContinuation { queue.append(Waiter(cost: cost, continuation: $0)) }
    }

    private func release(_ cost: Int) {
        used -= cost
        while head < queue.count, used + queue[head].cost <= capacity {
            let waiter = queue[head]
            head += 1
            used += waiter.cost
            waiter.continuation.resume()
        }
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
    }
}
