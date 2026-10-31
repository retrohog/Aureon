import Foundation

// What we share: only folders the user ticked, named by a share name and a path relative to it, never by a local path or the user's name.

public struct SlskShareFile: Equatable, Sendable {
    public var virtualPath: String      // "Share name\Album\01 Track.flac"
    public var localPath: String
    public var size: UInt64
    public init(virtualPath: String, localPath: String, size: UInt64) { self.virtualPath = virtualPath; self.localPath = localPath; self.size = size }
}

public enum SlskShares {
    /// The share name of a folder: its last path component.
    public static func shareName(_ folder: String) -> String { (folder as NSString).lastPathComponent }

    /// Maps files under the ticked folders to the paths peers see. Files outside every ticked folder are dropped.
    public static func build(files: [(path: String, size: UInt64)], folders: [String]) -> [SlskShareFile] {
        let roots = folders.map { ($0.hasSuffix("/") ? $0 : $0 + "/", shareName($0)) }
        var out: [SlskShareFile] = []
        for f in files {
            guard let r = roots.first(where: { f.path.hasPrefix($0.0) }) else { continue }
            let rel = String(f.path.dropFirst(r.0.count)).split(separator: "/").joined(separator: "\\")
            out.append(SlskShareFile(virtualPath: r.1 + "\\" + rel, localPath: f.path, size: f.size))
        }
        return out.sorted { $0.virtualPath < $1.virtualPath }
    }

    /// The directories and files count sent to the server.
    public static func counts(_ s: [SlskShareFile]) -> (folders: UInt32, files: UInt32) {
        (UInt32(Set(s.map { dir($0.virtualPath) }).count), UInt32(s.count))
    }

    static func dir(_ p: String) -> String { p.split(separator: "\\", omittingEmptySubsequences: false).dropLast().joined(separator: "\\") }

    /// The compressed share list answered to a SharedFileListRequest.
    public static func listResponse(_ s: [SlskShareFile]) -> SlskFrame {
        var byDir: [(String, [SlskShareFile])] = []
        for f in s { let d = dir(f.virtualPath); if let i = byDir.firstIndex(where: { $0.0 == d }) { byDir[i].1.append(f) } else { byDir.append((d, [f])) } }
        var w = SlskWriter(); w.u32(UInt32(byDir.count))
        for (d, files) in byDir {
            w.string(d); w.u32(UInt32(files.count))
            for f in files {
                let name = f.virtualPath.split(separator: "\\").last.map(String.init) ?? f.virtualPath
                w.u8(1); w.string(name); w.u64(f.size); w.string((name as NSString).pathExtension); w.u32(0)
            }
        }
        w.u32(0)    // private directories
        return SlskFrame(code: SlskCode.sharedFileListResponse, payload: SlskZlib.deflate(w.data))
    }

    /// Reads such a list back (for browsing a user).
    public static func parseList(_ f: SlskFrame) -> [SlskFileResult]? {
        guard f.code == SlskCode.sharedFileListResponse, let raw = SlskZlib.inflate(f.payload) else { return nil }
        var r = SlskReader(raw); var out: [SlskFileResult] = []
        guard let nd = r.u32(), nd < 200_000 else { return nil }
        for _ in 0..<nd {
            guard let d = r.string(), let nf = r.u32(), nf < 1_000_000 else { return nil }
            for _ in 0..<nf {
                guard r.u8() != nil, let name = r.string(), let size = r.u64(), let ext = r.string(), let na = r.u32(), na < 64 else { return nil }
                var res = SlskFileResult(path: d + "\\" + name, size: size, ext: ext, bitrate: nil, duration: nil, sampleRate: nil, bitDepth: nil, vbr: false)
                for _ in 0..<na { guard let k = r.u32(), let v = r.u32() else { return nil }; if k == 0 { res.bitrate = Int(v) }; if k == 4 { res.sampleRate = Int(v) }; if k == 5 { res.bitDepth = Int(v) } }
                out.append(res)
            }
        }
        return out
    }
}
