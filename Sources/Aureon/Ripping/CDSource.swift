import Foundation
import IOKit
import IOKit.storage

// Where the sectors come from: an optical drive (through the kernel's CD-DA ioctls) or a disc image (BIN/CUE).

struct SectorBlock {
    var audio: [UInt8]              // count × 2352 bytes
    var c2: [UInt8]?                // count × 294 bytes: one bit per audio byte, set where the drive's error correction gave up
    var count: Int
}

enum CDReadError: Error, Equatable {
    case io(Int32)
    case outOfRange
    case noDisc
    case unsupported(String)
}

protocol CDSource: AnyObject {
    var name: String { get }
    var toc: CDTOC { get }
    /// Whether the drive reports C2 error pointers with its audio.
    var supportsC2: Bool { get }
    func read(lba: Int, count: Int, c2: Bool) throws -> SectorBlock
    /// Makes the next read come from the disc rather than from the drive's cache (by reading somewhere else first).
    func flushCache()
}

extension SectorBlock {
    /// Sector `i` of the block.
    func sector(_ i: Int) -> ArraySlice<UInt8> { audio[(i * CDTOC.sectorBytes)..<((i + 1) * CDTOC.sectorBytes)] }
    func c2Bad(sector i: Int) -> Bool { c2.map { $0[(i * 294)..<((i + 1) * 294)].contains { $0 != 0 } } ?? false }
}

// MARK: - Disc image

/// A raw image of the audio sectors (2352 bytes each, as BIN files hold them) with its table of contents.
final class DiscImageSource: CDSource {
    let name: String
    let toc: CDTOC
    var supportsC2: Bool { false }
    private let fd: Int32
    private let sectors: Int

    init(binURL: URL, toc: CDTOC, name: String? = nil) throws {
        fd = Darwin.open(binURL.path, O_RDONLY)
        guard fd >= 0 else { throw CDReadError.io(errno) }
        self.toc = toc; self.name = name ?? binURL.lastPathComponent
        var st = stat(); fstat(fd, &st)
        sectors = Int(st.st_size) / CDTOC.sectorBytes
    }
    deinit { Darwin.close(fd) }

    func read(lba: Int, count: Int, c2: Bool) throws -> SectorBlock {
        guard lba >= 0, count > 0, lba + count <= sectors else { throw CDReadError.outOfRange }
        var buf = [UInt8](repeating: 0, count: count * CDTOC.sectorBytes)
        let n = pread(fd, &buf, buf.count, off_t(lba) * off_t(CDTOC.sectorBytes))
        guard n == buf.count else { throw CDReadError.io(n < 0 ? errno : EIO) }
        return SectorBlock(audio: buf, c2: nil, count: count)
    }

    func flushCache() {}

    /// Reads a CUE sheet that names one BIN file with audio tracks (the common form for a whole-disc image).
    static func image(cue: URL) throws -> DiscImageSource {
        let text = try String(contentsOf: cue, encoding: .utf8)
        var bin: URL?
        var tracks: [CDTrack] = []
        var current: (number: Int, audio: Bool)?
        func frames(_ s: String) -> Int? {
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 3 ? (p[0] * 60 + p[1]) * 75 + p[2] : nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first?.uppercased() else { continue }
            switch key {
            case "FILE":
                if bin == nil, let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 { bin = cue.deletingLastPathComponent().appendingPathComponent(String(line[line.index(after: q1)..<q2])) }
            case "TRACK":
                if parts.count >= 3, let n = Int(parts[1]) { current = (n, parts[2].uppercased() == "AUDIO") }
            case "INDEX":
                if parts.count >= 3, parts[1] == "01", let c = current, let f = frames(parts[2]) { tracks.append(CDTrack(number: c.number, startLBA: f, isAudio: c.audio)) }
            default: break
            }
        }
        guard let bin, !tracks.isEmpty else { throw CDReadError.unsupported("the CUE sheet has no BIN file or tracks") }
        var st = stat(); guard stat(bin.path, &st) == 0 else { throw CDReadError.io(errno) }
        let total = Int(st.st_size) / CDTOC.sectorBytes
        return try DiscImageSource(binURL: bin, toc: CDTOC(tracks: tracks, leadoutLBA: total), name: cue.deletingPathExtension().lastPathComponent)
    }
}

// MARK: - Optical drive

/// What the system reports about an inserted disc.
struct DiscInfo: Identifiable, Equatable {
    var id: String { bsdName }
    var bsdName: String             // "disk4"
    var driveName: String
    var toc: CDTOC
    var isAudio: Bool { !toc.audioTracks.isEmpty }
}

enum DiscScanner {
    /// Lists the audio discs in the machine's optical drives.
    static func scan() -> [DiscInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOCDMediaClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [DiscInfo] = []
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            func prop(_ key: String, _ entry: io_registry_entry_t = media) -> Any? { IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let bsd = prop(kIOBSDNameKey) as? String, (prop("Whole") as? Bool) == true, let tocData = prop(kIOCDMediaTOCKey) as? Data, let toc = CDTOC.parse(raw: tocData) else { continue }
            // the drive is a few levels up the registry
            var drive = "Optical drive"
            var entry = media
            for _ in 0..<6 {
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                if entry != media { IOObjectRelease(entry) }
                entry = parent
                if let ch = prop("Device Characteristics", entry) as? [String: Any], let vendor = ch["Vendor Name"] as? String, let product = ch["Product Name"] as? String {
                    drive = "\(vendor.trimmingCharacters(in: .whitespaces)) \(product.trimmingCharacters(in: .whitespaces))"; break
                }
            }
            if entry != media { IOObjectRelease(entry) }
            out.append(DiscInfo(bsdName: bsd, driveName: drive, toc: toc))
        }
        return out.sorted { $0.bsdName < $1.bsdName }
    }
}

/// Reads CD-DA sectors from `/dev/rdiskN` with DKIOCCDREAD (raw 2352-byte audio plus, where the drive offers them, the C2 error pointers).
final class IOKitDiscSource: CDSource {
    let name: String
    let toc: CDTOC
    private let fd: Int32
    private(set) var supportsC2 = false
    private var lastRead = 0

    // _IOWR('d', n, T) on Darwin: direction in/out, parameter size, group, number
    private static func iowr(_ n: UInt, _ size: Int) -> UInt { 0xC000_0000 | (UInt(size) & 0x1FFF) << 16 | UInt(UInt8(ascii: "d")) << 8 | n }
    private static var readRequest: UInt { iowr(96, MemoryLayout<dk_cd_read_t>.size) }
    private static let c2Bytes = 294

    init(disc: DiscInfo) throws {
        fd = Darwin.open("/dev/r\(disc.bsdName)", O_RDONLY)
        guard fd >= 0 else { throw CDReadError.io(errno) }
        toc = disc.toc; name = disc.driveName
        // does the drive answer a read with error pointers?
        if let first = disc.toc.audioTracks.first, (try? rawRead(lba: first.startLBA + 1_000, count: 1, c2: true)) != nil { supportsC2 = true }
    }
    deinit { Darwin.close(fd) }

    private func rawRead(lba: Int, count: Int, c2: Bool) throws -> SectorBlock {
        let per = CDTOC.sectorBytes + (c2 ? Self.c2Bytes : 0)
        var buf = [UInt8](repeating: 0, count: count * per)
        var req = dk_cd_read_t()
        req.offset = UInt64(lba) * UInt64(CDTOC.sectorBytes)
        req.sectorArea = UInt8(kCDSectorAreaUser.rawValue) | (c2 ? UInt8(kCDSectorAreaErrorFlags.rawValue) : 0)
        req.sectorType = UInt8(kCDSectorTypeCDDA.rawValue)
        req.bufferLength = UInt32(buf.count)
        let rc: Int32 = buf.withUnsafeMutableBytes { p in
            req.buffer = p.baseAddress
            return ioctl(fd, Self.readRequest, &req)
        }
        guard rc == 0, Int(req.bufferLength) >= buf.count else { throw CDReadError.io(rc == 0 ? EIO : errno) }
        if !c2 { return SectorBlock(audio: buf, c2: nil, count: count) }
        // each sector arrives as its audio followed by its error pointers
        var audio = [UInt8](repeating: 0, count: count * CDTOC.sectorBytes), flags = [UInt8](repeating: 0, count: count * Self.c2Bytes)
        for i in 0..<count {
            audio.replaceSubrange((i * CDTOC.sectorBytes)..<((i + 1) * CDTOC.sectorBytes), with: buf[(i * per)..<(i * per + CDTOC.sectorBytes)])
            flags.replaceSubrange((i * Self.c2Bytes)..<((i + 1) * Self.c2Bytes), with: buf[(i * per + CDTOC.sectorBytes)..<((i + 1) * per)])
        }
        return SectorBlock(audio: audio, c2: flags, count: count)
    }

    func read(lba: Int, count: Int, c2: Bool) throws -> SectorBlock {
        guard lba >= 0, lba + count <= toc.leadoutLBA else { throw CDReadError.outOfRange }
        lastRead = lba
        return try rawRead(lba: lba, count: count, c2: c2 && supportsC2)
    }

    /// A drive may answer a repeated read from its cache without touching the disc; reading a distant sector first makes it fetch again.
    func flushCache() {
        let far = lastRead > toc.leadoutLBA / 2 ? max(0, lastRead - 40_000) : min(toc.leadoutLBA - 30, lastRead + 40_000)
        _ = try? rawRead(lba: max(0, far), count: 26, c2: false)
    }

    /// Sets the drive's speed in multiples of 1× (176.4 kB/s). Slower reads are more reliable on a scratched disc.
    func setSpeed(_ multiplier: Int) {
        var kbps = UInt16(max(1, min(52, multiplier)) * 176)
        _ = ioctl(fd, 0x8002_0000 | UInt(2) << 16 | UInt(UInt8(ascii: "d")) << 8 | 99, &kbps)
    }
}
