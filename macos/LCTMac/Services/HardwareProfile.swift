import Foundation

/// Snapshot of the Mac's chip and memory, used to pick a translation model
/// the hardware can actually run (MLX builds need Apple Silicon; model size
/// must fit in memory).
struct HardwareProfile: Equatable, Sendable {
    let isAppleSilicon: Bool
    let physicalMemoryBytes: UInt64
    let chipName: String

    init(isAppleSilicon: Bool, physicalMemoryBytes: UInt64, chipName: String) {
        self.isAppleSilicon = isAppleSilicon
        self.physicalMemoryBytes = physicalMemoryBytes
        self.chipName = chipName
    }

    /// Whole gigabytes of memory, rounded (16 GB, 8 GB, …) for display.
    var memoryGB: Int {
        Int((Double(physicalMemoryBytes) / 1_073_741_824).rounded())
    }

    static func current() -> HardwareProfile {
        // hw.optional.arm64 reflects the chip even when this process runs
        // under Rosetta, unlike `uname -m` or #if arch(arm64).
        let appleSilicon = sysctlInt32("hw.optional.arm64") == 1
        let chip = sysctlString("machdep.cpu.brand_string") ?? (appleSilicon ? "Apple Silicon" : "Intel")
        return HardwareProfile(
            isAppleSilicon: appleSilicon,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            chipName: chip
        )
    }

    private static func sysctlInt32(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        return result == 0 ? value : 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
