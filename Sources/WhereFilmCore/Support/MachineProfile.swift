import Foundation
import CoreML

/// What kind of Mac this is, asked of the machine rather than assumed.
///
/// Every performance constant in this project was measured on one laptop — a
/// MacBook Air M4 with ten cores, sixteen gigabytes and a neural engine — and
/// several of them are written as `activeProcessorCount` arithmetic, which reads
/// like adaptation and is not. A 2019 Intel i9 reports sixteen logical cores and
/// has no neural engine at all; the same arithmetic hands it settings tuned for
/// silicon it does not have.
///
/// macOS 26 is the last release that runs on Intel, so this is a finite problem
/// with a real deadline, and the answer is not to guess better. It is to ask.
public struct MachineProfile: Sendable {
    public enum Silicon: String, Sendable {
        case appleSilicon
        case intel
    }

    public let silicon: Silicon
    /// Logical cores, as the scheduler sees them.
    public let cores: Int
    /// Performance cores only. On Apple silicon the efficiency cores are real
    /// but slow for inference; on Intel this equals `cores`.
    public let performanceCores: Int
    public let memoryGB: Double
    /// The question that actually matters, asked functionally: is there a neural
    /// engine to send Core ML to? `.cpuAndNeuralEngine` on a machine without one
    /// is a long way of writing `.cpuOnly`.
    public let hasNeuralEngine: Bool
    public let gpuNames: [String]
    /// An x86_64 build running on Apple silicon through Rosetta. Correctness
    /// tests are meaningful here; timings are not.
    public let isTranslated: Bool

    public static let current = MachineProfile()

    public init() {
        let translated = Self.sysctlInt("sysctl.proc_translated") == 1
        // `hw.optional.arm64` is the honest answer about the hardware even when
        // the process itself is x86_64 under translation.
        let isARM = Self.sysctlInt("hw.optional.arm64") == 1
        self.isTranslated = translated
        self.silicon = isARM ? .appleSilicon : .intel
        self.cores = ProcessInfo.processInfo.activeProcessorCount
        self.performanceCores = Self.sysctlInt("hw.perflevel0.logicalcpu")
            .map(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount
        self.memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

        var neuralEngine = false
        var gpus: [String] = []
        for device in MLComputeDevice.allComputeDevices {
            switch device {
            case .neuralEngine: neuralEngine = true
            case .gpu(let gpu): gpus.append(gpu.metalDevice.name)
            default: break
            }
        }
        self.hasNeuralEngine = neuralEngine
        self.gpuNames = gpus
    }

    /// Test seam: build a profile for a machine that is not this one.
    public init(silicon: Silicon, cores: Int, performanceCores: Int, memoryGB: Double,
                hasNeuralEngine: Bool, gpuNames: [String] = [], isTranslated: Bool = false) {
        self.silicon = silicon
        self.cores = cores
        self.performanceCores = performanceCores
        self.memoryGB = memoryGB
        self.hasNeuralEngine = hasNeuralEngine
        self.gpuNames = gpuNames
        self.isTranslated = isTranslated
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            // Some of these are 32-bit; ask again rather than reporting nothing.
            var small: Int32 = 0
            var smallSize = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
            return Int64(small)
        }
        return value
    }

    public var summary: String {
        var parts = ["\(silicon == .appleSilicon ? "Apple silicon" : "Intel")"]
        if isTranslated { parts.append("running translated (Rosetta)") }
        parts.append("\(cores) cores (\(performanceCores) performance)")
        parts.append(String(format: "%.0f GB", memoryGB))
        parts.append(hasNeuralEngine ? "neural engine present" : "no neural engine")
        if !gpuNames.isEmpty { parts.append("GPU: \(gpuNames.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

/// Which silicon Core ML should be allowed to use, given the machine and what
/// else the person is doing with it.
///
/// The single hard-coded `.cpuAndNeuralEngine` this replaces was exactly right
/// for its purpose — stay off the GPU DaVinci Resolve is hammering — and exactly
/// wrong on a Mac with no neural engine, where it silently means "CPU only,
/// forever", including while the machine sits idle with a perfectly good GPU.
public enum ComputePolicy {
    /// `editorRunning` is the governor's existing signal: Resolve, Premiere,
    /// Final Cut and friends open or frontmost.
    public static func imageEncoding(profile: MachineProfile = .current,
                                     editorRunning: Bool) -> MLComputeUnits {
        guard !profile.hasNeuralEngine else {
            // Unchanged, and deliberately: the ANE is idle while an editor
            // punishes the GPU, which is the whole reason this app can coexist
            // with one.
            return .cpuAndNeuralEngine
        }
        // No neural engine. The GPU is the only accelerator there is, so the
        // choice is between using the thing the editor wants and being slow.
        // Yield while an editor is running; take it when nobody else needs it.
        return editorRunning ? .cpuOnly : .cpuAndGPU
    }

    /// Where Vision should run its heavy stages. `nil` means "let Vision decide",
    /// which is right whenever we have nothing better to say.
    public static func visionDevice(profile: MachineProfile = .current,
                                    editorRunning: Bool) -> MLComputeDevice? {
        guard !profile.hasNeuralEngine, editorRunning else { return nil }
        // Same trade as above: on Intel with an editor open, keep OCR off the GPU
        // even though it is slower, because a stuttering timeline is a bug the
        // person will notice and a slower background index is not.
        return MLComputeDevice.allComputeDevices.first { device in
            if case .cpu = device { return true }
            return false
        }
    }
}
