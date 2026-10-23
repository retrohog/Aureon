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
    /// MLX runs on Apple Silicon only (Metal on the unified-memory GPU), and not inside a Rosetta-translated process.
    var canRunMLX: Bool { isAppleSilicon && !isTranslated }

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

    /// The badge on the Intelligence page.
    var badgeTitle: String {
        if isIntel { return "Intel x86 · Software Mode" }
        return isTranslated ? "Apple Silicon · Running under Rosetta" : "Apple M-Series Neural Engine Active"
    }

    var badgeDetail: String {
        var parts = [cpuBrand]
        if memoryBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory) + " memory") }
        if efficiencyCores > 0 { parts.append("\(performanceCores)P + \(efficiencyCores)E cores") } else { parts.append("\(performanceCores) cores") }
        return parts.joined(separator: " · ")
    }
}

extension HostHardware {
    /// The line shown next to a control that cannot work on an Intel Mac, followed by the reason.
    static let appleSiliconOnlyNote = "Only available on Apple Silicon Macs"

    /// Why the on-device language model (MLX) cannot be used on this Mac, or nil when it can be tried. Only a real Intel Mac is blocked here:
    /// under Rosetta the existing "needs the native build" messages apply instead.
    var localLanguageModelBlocker: String? {
        isIntel ? "Needs Apple's MLX framework, which runs only on M-series chips." : nil
    }

    /// Why the Real-Time Audio Enhancer is unavailable on this Mac, or nil when it can be switched on.
    var audioEnhancerBlocker: String? {
        isIntel ? "Needs the Neural Engine, which only M-series chips have; on an Intel CPU it cannot keep up with real time." : nil
    }
}

/// Which processor types a Mach-O executable contains, read from its header. A helper program built for one architecture only
/// (the MLX one is arm64-only) must not be launched on the other, so a missing slice is treated like a missing helper.
enum MachOSlices {
    private static let cpuARM64: UInt32 = 0x0100000C
    private static let cpuX86_64: UInt32 = 0x01000007

    /// False only when `url` is a recognisable Mach-O (thin or universal) without a slice for `hardware`. Anything else, such as a
    /// script, is left to the system to run or refuse.
    static func canRun(_ url: URL, on hardware: HostHardware = .current) -> Bool {
        guard let types = cpuTypes(of: url) else { return true }
        return types.contains(hardware.isIntel ? cpuX86_64 : cpuARM64)
    }

    static func cpuTypes(of url: URL) -> [UInt32]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8 + 20 * 8), head.count >= 8 else { return nil }
        let b = [UInt8](head)
        func be32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        func le32(_ o: Int) -> UInt32 { UInt32(b[o + 3]) << 24 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 1]) << 8 | UInt32(b[o]) }
        switch be32(0) {
        case 0xCAFEBABE:                                    // universal: a table of 20-byte entries, cputype first
            let n = Int(be32(4))
            guard n > 0, n <= 20, head.count >= 8 + 20 * n else { return nil }
            return (0..<n).map { be32(8 + 20 * $0) }
        case 0xCFFAEDFE:                                    // thin 64-bit, little-endian
            return [le32(4)]
        default:
            return nil
        }
    }
}
