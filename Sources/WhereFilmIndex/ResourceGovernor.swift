import Foundation
import AppKit
import IOKit.ps
import WhereFilmCore

public enum IndexerMode: String, Sendable, CaseIterable, Codable {
    case smart
    case paused
    case fullSpeed

    public var label: String {
        switch self {
        case .smart: "Smart"
        case .paused: "Paused"
        case .fullSpeed: "Full speed"
        }
    }
}

/// Why the indexer is not currently working. Shown verbatim in the menu bar so
/// the state is never mysterious.
public enum ThrottleReason: String, Sendable {
    case none
    case userPaused
    case thermal
    case lowPower
    case onBattery
    case lowBattery
    case editorInForeground
    case editorRunning
    case searchActive

    public var label: String {
        switch self {
        case .none: "Working"
        case .userPaused: "Paused by you"
        case .thermal: "Paused — the Mac is running hot"
        case .lowPower: "Paused — Low Power Mode"
        case .onBattery: "Light mode — on battery"
        case .lowBattery: "Paused — battery is low"
        case .editorInForeground: "Paused — you're editing"
        case .editorRunning: "Light mode — an editor is open"
        case .searchActive: "Paused — search has priority"
        }
    }
}

public struct GovernorDecision: Sendable {
    public let allowedTasks: [JobTask]
    public let concurrency: Int
    /// How many independent mounted-volume scans may run at once. Scanning one
    /// volume remains serial to avoid seeking against itself; separate disks can
    /// make progress together when the machine is otherwise idle.
    public let scanConcurrency: Int
    public let reason: ThrottleReason

    public init(allowedTasks: [JobTask], concurrency: Int,
                scanConcurrency: Int = 1, reason: ThrottleReason) {
        self.allowedTasks = allowedTasks
        self.concurrency = concurrency
        self.scanConcurrency = scanConcurrency
        self.reason = reason
    }

    public var isWorking: Bool { !allowedTasks.isEmpty }
}

/// A testable snapshot of the signals that drive Smart mode. The live provider
/// is intentionally kept in `ResourceGovernor`, while tests can describe a Mac
/// with an editor open or a battery without depending on the host running them.
public struct ResourceSnapshot: Sendable, Equatable {
    public enum ThermalLevel: String, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    public var thermalLevel: ThermalLevel
    public var isLowPowerModeEnabled: Bool
    public var onACPower: Bool
    public var batteryCharge: Double?
    public var frontmostBundleIdentifier: String?
    public var runningBundleIdentifiers: Set<String>

    public init(thermalLevel: ThermalLevel = .nominal,
                isLowPowerModeEnabled: Bool = false,
                onACPower: Bool = true,
                batteryCharge: Double? = nil,
                frontmostBundleIdentifier: String? = nil,
                runningBundleIdentifiers: Set<String> = []) {
        self.thermalLevel = thermalLevel
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.onACPower = onACPower
        self.batteryCharge = batteryCharge
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }
}

/// Decides, moment to moment, whether the indexer may work and how hard.
///
/// Being honest about this matters: no AI analysis is free. Two processes on one
/// machine share memory bandwidth, CPU, storage and accelerators, so nobody can
/// promise that indexing 30 TB is invisible. What *can* be promised is that the
/// indexer runs at minimum priority and gets out of the way aggressively.
public struct ResourceGovernor: Sendable {
    public struct Settings: Sendable, Codable {
        public var mode: IndexerMode = .smart
        /// Set by "Pause for 2h" in the menu bar.
        public var pausedUntil: Date?
        /// In Smart mode, back off when one of these is running, and yield all
        /// expensive work when one is frontmost.
        public var editorBundleIDs: Set<String> = [
            "com.blackmagic-design.DaVinciResolve",
            "com.adobe.PremierePro",
            "com.adobe.AfterEffects",
            "com.apple.FinalCut",
            "com.apple.Compressor",
            "com.adobe.MediaEncoder",
            "com.blackmagicdesign.fusion",
        ]
        /// On battery WhereFilm keeps indexing, just more gently: fewer jobs
        /// at once and no transcription, which is by far the most expensive
        /// task. It used to drop to metadata-only, and the effect on a laptop
        /// was an index that never became searchable at all — 151 files, zero
        /// moments, forever. A search tool that only works while plugged in is
        /// not a search tool.
        public var batteryFloor: Double = 0.25
        /// How many jobs may be in flight at once.
        ///
        /// This used to be capped at four on the theory that workers block
        /// inside GRDB and AVFoundation and that oversubscribing the cooperative
        /// pool would deadlock. Blocking is exactly why more workers help — while
        /// one waits on the disk another can compute — and the measurement says
        /// so plainly. 203 photographs on a 10-core M4:
        ///
        ///     4 workers → 20.5 s      8 workers → 12.0 s      12 workers → 11.1 s
        ///
        /// Four workers left 60% of the machine idle and could never fill the
        /// eight Vision slots the hardware happily sustains, because a photo job
        /// issues exactly one recognition request.
        ///
        /// Raising it is only safe because memory no longer scales with this
        /// number: `WorkBudget` caps decoded frames in flight, so a wave of video
        /// passes self-limits to a couple at a time while a wave of stills runs
        /// wide. Past the core count there is nothing left to win.
        public var maxConcurrency = max(2, min(12, ProcessInfo.processInfo.activeProcessorCount))

        public init() {}
    }

    public var settings: Settings
    private let snapshotOverride: ResourceSnapshot?

    public init(settings: Settings = Settings(), snapshot: ResourceSnapshot? = nil) {
        self.settings = settings
        self.snapshotOverride = snapshot
    }

    public func decide(now: Date = Date()) -> GovernorDecision {
        let snapshot = snapshotOverride ?? Self.liveSnapshot()
        if let until = settings.pausedUntil, until > now {
            return GovernorDecision(allowedTasks: [], concurrency: 0,
                                    scanConcurrency: 0, reason: .userPaused)
        }

        switch settings.mode {
        case .paused:
            return GovernorDecision(allowedTasks: [], concurrency: 0,
                                    scanConcurrency: 0, reason: .userPaused)
        case .fullSpeed:
            // The user explicitly asked for everything. Still respect a critical
            // thermal state — that is the machine protecting itself, not a
            // preference.
            if snapshot.thermalLevel == .critical {
                return GovernorDecision(allowedTasks: [], concurrency: 0,
                                        scanConcurrency: 0, reason: .thermal)
            }
            // "Full speed" means *every task type*, not an unbounded number of
            // workers: the pool above is already the safe ceiling.
            return GovernorDecision(allowedTasks: JobTask.allCases,
                                    concurrency: max(1, settings.maxConcurrency),
                                    scanConcurrency: scanWidth,
                                    reason: .none)
        case .smart:
            return smartDecision(snapshot: snapshot)
        }
    }

    private func smartDecision(snapshot: ResourceSnapshot) -> GovernorDecision {
        switch snapshot.thermalLevel {
        case .critical:
            return GovernorDecision(allowedTasks: [], concurrency: 0,
                                    scanConcurrency: 0, reason: .thermal)
        case .serious:
            // Still make progress on the near-free work, but only one at a time.
            return GovernorDecision(allowedTasks: [.metadata], concurrency: 1,
                                    scanConcurrency: 1, reason: .thermal)
        default:
            break
        }

        if snapshot.isLowPowerModeEnabled {
            // Keep visual/OCR discovery alive at one worker. Delaying these
            // forever makes the catalog technically present but not useful.
            return GovernorDecision(allowedTasks: [.metadata, .visual, .ocr],
                                    concurrency: 1, scanConcurrency: 1,
                                    reason: .lowPower)
        }

        let editorIsFrontmost = settings.editorBundleIDs.contains(
            snapshot.frontmostBundleIdentifier ?? "")
        let editorIsRunning = !snapshot.runningBundleIdentifiers
            .intersection(settings.editorBundleIDs).isEmpty

        if editorIsFrontmost {
            // Directory discovery and metadata are cheap and preserve move/name
            // accuracy. Heavy analysis waits until the editor yields the machine.
            return GovernorDecision(allowedTasks: [.metadata], concurrency: 1,
                                    scanConcurrency: 1, reason: .editorInForeground)
        }

        if editorIsRunning {
            // Keep the library becoming semantically searchable, but defer the
            // two broadest consumers: speech decoding and full-file hashing.
            return GovernorDecision(allowedTasks: [.metadata, .visual, .ocr],
                                    concurrency: 1, scanConcurrency: 1,
                                    reason: .editorRunning)
        }

        if !snapshot.onACPower {
            // Genuinely low: leave the remaining charge to the person using the
            // Mac.
            if let charge = snapshot.batteryCharge, charge < settings.batteryFloor {
                return GovernorDecision(allowedTasks: [.metadata, .visual], concurrency: 1,
                                        scanConcurrency: 1, reason: .lowBattery)
            }
            // Otherwise keep making the library searchable. Visual + OCR are
            // what turn files into findable moments; transcription and the
            // full-file hash are the two genuinely heavy tasks, so they wait
            // for a power outlet.
            return GovernorDecision(allowedTasks: [.metadata, .visual, .ocr],
                                    concurrency: max(1, settings.maxConcurrency / 2),
                                    scanConcurrency: 1,
                                    reason: .onBattery)
        }

        return GovernorDecision(
            allowedTasks: [.metadata, .visual, .ocr, .transcribe, .strongHash],
            concurrency: max(1, settings.maxConcurrency),
            scanConcurrency: scanWidth,
            reason: .none)
    }

    private var scanWidth: Int {
        min(4, max(1, settings.maxConcurrency / 2))
    }

    /// When Resolve is in front the user wants every cycle for the timeline.
    public func isEditorFrontmost() -> Bool {
        let snapshot = snapshotOverride ?? Self.liveSnapshot()
        return settings.editorBundleIDs.contains(snapshot.frontmostBundleIdentifier ?? "")
    }

    /// True when an editor is open even if another app currently has focus.
    public func isEditorRunning() -> Bool {
        let snapshot = snapshotOverride ?? Self.liveSnapshot()
        return !snapshot.runningBundleIdentifiers
            .intersection(settings.editorBundleIDs).isEmpty
    }

    public func isOnACPower() -> Bool {
        (snapshotOverride ?? Self.liveSnapshot()).onACPower
    }

    /// Fraction of a full charge, or nil on a machine with no battery.
    public func batteryCharge() -> Double? {
        (snapshotOverride ?? Self.liveSnapshot()).batteryCharge
    }

    private static func liveSnapshot() -> ResourceSnapshot {
        let info = ProcessInfo.processInfo
        let thermal: ResourceSnapshot.ThermalLevel
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }

        let power = livePowerState()
        return ResourceSnapshot(
            thermalLevel: thermal,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            onACPower: power.onACPower,
            batteryCharge: power.batteryCharge,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            runningBundleIdentifiers: Set(NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)))
    }

    private static func livePowerState() -> (onACPower: Bool, batteryCharge: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (true, nil) }

        // A desktop with no battery reports no sources at all — treat that as
        // plugged in, because it is.
        if sources.isEmpty { return (true, nil) }

        var onACPower = true
        var charge: Double?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                onACPower = state == kIOPSACPowerValue
            }
            // IOKit commonly bridges these values as NSNumber/Int rather than
            // Double. Casting straight to Double made the low-battery guard a
            // no-op on real Macs even though it looked correct in tests.
            if let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
               let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
               maximum > 0 {
                charge = current / maximum
            }
        }
        return (onACPower, charge)
    }

    public var thermalStateDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
