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

    public var label: String {
        switch self {
        case .none: "Working"
        case .userPaused: "Paused by you"
        case .thermal: "Paused — the Mac is running hot"
        case .lowPower: "Paused — Low Power Mode"
        case .onBattery: "Light mode — on battery"
        case .lowBattery: "Paused — battery is low"
        case .editorInForeground: "Paused — you're editing"
        }
    }
}

public struct GovernorDecision: Sendable {
    public let allowedTasks: [JobTask]
    public let concurrency: Int
    public let reason: ThrottleReason

    public var isWorking: Bool { !allowedTasks.isEmpty }
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
        /// In Smart mode, back off when one of these is frontmost.
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

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public func decide(now: Date = Date()) -> GovernorDecision {
        if let until = settings.pausedUntil, until > now {
            return GovernorDecision(allowedTasks: [], concurrency: 0, reason: .userPaused)
        }

        switch settings.mode {
        case .paused:
            return GovernorDecision(allowedTasks: [], concurrency: 0, reason: .userPaused)
        case .fullSpeed:
            // The user explicitly asked for everything. Still respect a critical
            // thermal state — that is the machine protecting itself, not a
            // preference.
            if ProcessInfo.processInfo.thermalState == .critical {
                return GovernorDecision(allowedTasks: [], concurrency: 0, reason: .thermal)
            }
            // "Full speed" means *every task type*, not an unbounded number of
            // workers: the pool above is already the safe ceiling.
            return GovernorDecision(allowedTasks: JobTask.allCases,
                                    concurrency: max(1, settings.maxConcurrency),
                                    reason: .none)
        case .smart:
            return smartDecision()
        }
    }

    private func smartDecision() -> GovernorDecision {
        let info = ProcessInfo.processInfo

        switch info.thermalState {
        case .critical:
            return GovernorDecision(allowedTasks: [], concurrency: 0, reason: .thermal)
        case .serious:
            // Still make progress on the near-free work, but only one at a time.
            return GovernorDecision(allowedTasks: [.metadata], concurrency: 1, reason: .thermal)
        default:
            break
        }

        if info.isLowPowerModeEnabled {
            return GovernorDecision(allowedTasks: [.metadata], concurrency: 1, reason: .lowPower)
        }

        if isEditorFrontmost() {
            return GovernorDecision(allowedTasks: [], concurrency: 0, reason: .editorInForeground)
        }

        if !isOnACPower() {
            // Genuinely low: leave the remaining charge to the person using the
            // Mac.
            if let charge = batteryCharge(), charge < settings.batteryFloor {
                return GovernorDecision(allowedTasks: [.metadata], concurrency: 1,
                                        reason: .lowBattery)
            }
            // Otherwise keep making the library searchable. Visual + OCR are
            // what turn files into findable moments; transcription and the
            // full-file hash are the two genuinely heavy tasks, so they wait
            // for a power outlet.
            return GovernorDecision(allowedTasks: [.metadata, .visual, .ocr],
                                    concurrency: max(1, settings.maxConcurrency / 2),
                                    reason: .onBattery)
        }

        return GovernorDecision(
            allowedTasks: [.metadata, .visual, .ocr, .transcribe, .strongHash],
            concurrency: max(1, settings.maxConcurrency),
            reason: .none)
    }

    /// When Resolve is in front the user wants every cycle for the timeline.
    public func isEditorFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return settings.editorBundleIDs.contains(bundleID)
    }

    public func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }

        // A desktop with no battery reports no sources at all — treat that as
        // plugged in, because it is.
        if sources.isEmpty { return true }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }

    /// Fraction of a full charge, or nil on a machine with no battery.
    public func batteryCharge() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            // IOKit commonly bridges these values as NSNumber/Int rather than
            // Double. Casting straight to Double made the low-battery guard a
            // no-op on real Macs even though it looked correct in tests.
            guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  maximum > 0 else { continue }
            return current / maximum
        }
        return nil
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
