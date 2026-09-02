import Foundation

/// Caps how many Vision requests are in flight across the whole process.
///
/// ## This gate is a crash guard, not a tuning knob
///
/// `RecognizeTextRequest` is not safe to run deeply concurrent on
/// macOS 26.5.2. Past roughly three simultaneous requests it corrupts memory
/// inside Apple's own framework while tearing down recognition results:
///
///     EXC_BAD_ACCESS (SIGSEGV) — KERN_INVALID_ADDRESS
///     objc_release ← TextRecognition ← swift_release_dealloc ← Vision ×10
///
/// Measured by re-indexing the same six reels repeatedly on a 10-core M4,
/// counting non-zero exits:
///
///     depth 2 →  0/20 runs crashed
///     depth 3 →  0/20 runs crashed
///     depth 4 →  2/10 runs crashed
///     depth 8 →  5/10 runs crashed
///
/// It is dose-dependent and independent of how many indexer workers are running
/// (depth 2 with twelve workers is clean; depth 8 with four workers is not).
/// Routing through `ImageRequestHandler` instead of `perform(on:)` does not help
/// — same 5/10. Moving MobileCLIP off the neural engine does not help either, so
/// it is not accelerator contention. The fault is inside TextRecognition.
///
/// This is expensive to accept. Vision genuinely scales — 40 keyframes through a
/// pipeline of depth N, `.accurate`, same machine:
///
///     depth 1 →  6.16 s      depth 4 →  2.14 s
///     depth 2 →  3.11 s      depth 8 →  1.35 s   ← 4.6×, and unusable
///
/// OCR is about 90% of the visual pass, so the crash ceiling is the single
/// biggest limit on how fast this app can index. Three is the most the framework
/// survives, so three is what we take. **Do not raise this without re-running
/// the stress measurement above** — the failure is intermittent, so a build that
/// "works on my machine" proves nothing.
///
/// ## Depth is not the only trigger — overlap is
///
/// Depth 3 was clean for 20 runs while the indexer still did its per-job work on
/// an actor, which meant exactly one Core ML encode could run at a time. Moving
/// that work off the actor (a 3× throughput win) let MobileCLIP run *alongside*
/// Vision, and the crash came back at 3/20 even at depth 3. Reproduced in
/// isolation: Vision at depth 8 alone survives 8 rounds; Vision at depth 8 with
/// concurrent Core ML dies on round 4 — and it still dies with Core ML forced to
/// `cpuOnly`, so this is not accelerator contention, it is Vision objecting to
/// concurrent heavy image work in the same process.
///
/// So the gate does two things now: it bounds how many Vision requests run at
/// once, *and* it guarantees that Core ML image encoding never overlaps them.
/// Exclusivity is nearly free — a batch of 8 embeddings is ~40 ms against ~530 ms
/// of OCR for the same batch — and it is the difference between an indexer that
/// finishes and one that segfaults on one library in seven.
///
/// A third, older reason the gate exists: Vision blocks the calling thread when
/// its internal queue is full
/// (`-[VNControlledCapacityTasksQueue dispatchSyncByPreservingQueueCapacity:]`),
/// and Swift's cooperative pool does not grow to cover blocked threads. An
/// unbounded flood parks every thread inside Vision with none left to drain the
/// queue they are all waiting on.
public actor VisionGate {
    public static let shared = VisionGate()

    /// The deepest queue TextRecognition survives, bounded again by the cores
    /// available so a small Mac never hands Vision its whole cooperative pool.
    public static var recommendedLimit: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(Self.crashCeiling, cores - 2))
    }

    /// The measured limit of Apple's framework. Raising this is a correctness
    /// change, not a performance one — see the stress table above.
    public static let crashCeiling = 2

    private let limit: Int
    private var inFlight = 0
    private var exclusiveHeld = false

    private enum Mode { case shared, exclusive }
    private struct Waiter {
        let mode: Mode
        let continuation: CheckedContinuation<Void, Never>
    }
    private var waiting: [Waiter] = []
    /// Cursor instead of `removeFirst`: indexing a long video queues thousands
    /// of frames, and shifting the array for each one is quadratic.
    private var nextWaiter = 0

    public init(limit: Int? = nil) {
        self.limit = max(1, limit ?? Self.recommendedLimit)
    }

    /// How many Vision requests may run at once.
    public var capacity: Int { limit }

    /// Runs a Vision request, sharing the gate with other Vision requests but
    /// never with Core ML.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(.shared)
        defer { release(.shared) }
        return try await body()
    }

    /// Runs Core ML image work with every Vision request drained and held off.
    ///
    /// `body` is synchronous on purpose: `MLModel.predictions(fromBatch:)`
    /// blocks its thread, and holding the gate across that block is exactly what
    /// stops Vision from being underneath it.
    public func runExclusive<T: Sendable>(_ body: @Sendable () throws -> T) async rethrows -> T {
        await acquire(.exclusive)
        defer { release(.exclusive) }
        return try body()
    }

    private func canStart(_ mode: Mode) -> Bool {
        switch mode {
        case .shared: !exclusiveHeld && inFlight < limit
        case .exclusive: !exclusiveHeld && inFlight == 0
        }
    }

    private func begin(_ mode: Mode) {
        switch mode {
        case .shared: inFlight += 1
        case .exclusive: exclusiveHeld = true
        }
    }

    private func acquire(_ mode: Mode) async {
        // Strict FIFO. Letting a ready Vision request overtake a waiting Core ML
        // encode would starve the encode for as long as frames keep arriving,
        // which on a long video is "forever".
        if nextWaiter == waiting.count, canStart(mode) {
            begin(mode)
            return
        }
        await withCheckedContinuation { waiting.append(Waiter(mode: mode, continuation: $0)) }
    }

    private func release(_ mode: Mode) {
        switch mode {
        case .shared: inFlight -= 1
        case .exclusive: exclusiveHeld = false
        }
        while nextWaiter < waiting.count, canStart(waiting[nextWaiter].mode) {
            let waiter = waiting[nextWaiter]
            nextWaiter += 1
            begin(waiter.mode)
            waiter.continuation.resume()
        }
        if nextWaiter == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            nextWaiter = 0
        }
    }
}

