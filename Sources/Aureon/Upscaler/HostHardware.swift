import Foundation
import Darwin

/// Reads sysctl values. The real one asks the kernel; tests pass a dictionary.
protocol SysctlReading: Sendable {
    func int(_ name: String) -> Int64?
    func string(_ name: String) -> String?
}

struct KernelSysctl: SysctlReading {
    func int(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 8 else { return nil }
        var raw: UInt64 = 0
        guard sysctlbyname(name, &raw, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 1: return Int64(Int8(truncatingIfNeeded: raw))
        case 2: return Int64(Int16(truncatingIfNeeded: raw))
        case 4: return Int64(Int32(truncatingIfNeeded: raw))
        default: return Int64(bitPattern: raw)
        }
    }

    func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// What the Mac running Aureon is made of, read once at launch.
///
/// The architecture comes from the hardware, not from how this binary was built: `hw.optional.arm64` is 1 on Apple Silicon even when an
/// x86_64 build runs under Rosetta, so a translated copy is still treated as Apple Silicon (and told it is translated).
struct HostHardware: Equatable, Sendable {
    enum Architecture: String, Codable, Sendable { case appleSilicon, intel }

    var architecture: Architecture
    /// This process is an x86_64 binary running under Rosetta 2 on Apple Silicon.
    var isTranslated: Bool
    var cpuBrand: String
    var memoryBytes: UInt64
    var performanceCores: Int
    var efficiencyCores: Int

    var isAppleSilicon: Bool { architecture == .appleSilicon }
    var isIntel: Bool { architecture == .intel }
    /// Every Apple Silicon Mac has a Neural Engine; no Intel Mac does.
    var hasNeuralEngine: Bool { isAppleSilicon }

    static let current = HostHardware.detect()

    static func detect(_ sysctl: SysctlReading = KernelSysctl()) -> HostHardware {
        let arm = (sysctl.int("hw.optional.arm64") ?? 0) == 1
        let translated = (sysctl.int("sysctl.proc_translated") ?? 0) == 1
        let brand = sysctl.string("machdep.cpu.brand_string") ?? (arm ? "Apple Silicon" : "Intel")
        let mem = UInt64(max(0, sysctl.int("hw.memsize") ?? 0))
        let physical = Int(sysctl.int("hw.physicalcpu") ?? 0)
        // Apple Silicon reports performance (level 0) and efficiency (level 1) clusters separately; Intel has one kind of core.
        let p = Int(sysctl.int("hw.perflevel0.physicalcpu") ?? 0)
        let e = Int(sysctl.int("hw.perflevel1.physicalcpu") ?? 0)
        return HostHardware(architecture: arm ? .appleSilicon : .intel, isTranslated: translated, cpuBrand: brand, memoryBytes: mem,
                            performanceCores: p > 0 ? p : max(1, physical), efficiencyCores: p > 0 ? e : 0)
    }

}

extension HostHardware {
    /// Why the Real-Time Audio Enhancer is unavailable on this Mac, or nil when it can be switched on.
    var audioEnhancerBlocker: String? {
        isIntel ? "Needs the Neural Engine, which only M-series chips have; on an Intel CPU it cannot keep up with real time." : nil
    }
}
