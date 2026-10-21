import Foundation

// Audio fingerprinting. Chromaprint's fingerprint algorithm is intricate and AcoustID only accepts exact Chromaprint
// fingerprints, so Aureon uses the reference `fpcalc` tool (brew install chromaprint) instead of a lookalike port.

struct Fingerprint: Equatable { var duration: Int; var value: String }

protocol Fingerprinter: Sendable {
    func fingerprint(path: String) async throws -> Fingerprint
}

struct FpcalcFingerprinter: Fingerprinter {
    var explicitPath: String? = nil

    static func locate(_ explicit: String? = nil) -> String? {
        let candidates = [explicit, "/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc", "/usr/bin/fpcalc", Bundle.main.resourcePath.map { $0 + "/fpcalc" }].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parses `fpcalc -json` output: {"duration": 187.4, "fingerprint": "AQAA…"}.
    static func parse(_ d: Data) throws -> Fingerprint {
        let j = try parseJSON(d)
        guard let fp = j.str("fingerprint"), let dur = j.num("duration"), !fp.isEmpty else { throw NetworkError.badResponse("fpcalc returned no fingerprint") }
        return Fingerprint(duration: Int(dur.rounded()), value: fp)
    }

    func fingerprint(path: String) async throws -> Fingerprint {
        guard let exe = Self.locate(explicitPath) else { throw AureonError.message("fpcalc is not installed. Install Chromaprint (brew install chromaprint) to identify untagged files.") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["-json", "-length", "120", path]
                let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: AureonError.message("fpcalc failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")); return
                }
                do { cont.resume(returning: try Self.parse(data)) } catch { cont.resume(throwing: error) }
            }
        }
    }
}

struct AcoustIDMatch: Codable, Hashable {
    var score: Double
    var recordingID: String
    var title: String?
    var artists: [MBArtistRef]
    var releaseGroups: [MBRelease]
}

final class AcoustIDClient: @unchecked Sendable {
    private let http: HTTPClient, identity: ClientIdentity
    private let limiter = RateLimiter(interval: 0.34)             // AcoustID allows 3 requests per second
    var endpoint = URL(string: "https://api.acoustid.org/v2/lookup")!

    init(http: HTTPClient = URLSessionClient(), identity: ClientIdentity = ClientIdentity()) { self.http = http; self.identity = identity }

    static func parse(_ d: Data) throws -> [AcoustIDMatch] {
        let j = try parseJSON(d)
        if j.str("status") == "error" { throw NetworkError.badResponse("AcoustID: " + (j.obj("error")?.str("message") ?? "error")) }
        var out: [AcoustIDMatch] = []
        for r in j.arr("results") {
            let score = r.num("score") ?? 0
            for rec in r.arr("recordings") {
                guard let id = rec.str("id") else { continue }
                let rgs: [MBRelease] = rec.arr("releasegroups").compactMap { g in
                    guard let gid = g.str("id") else { return nil }
                    return MBRelease(id: gid, title: g.str("title") ?? "", releaseGroupID: gid, releaseGroupTitle: g.str("title"), primaryType: g.str("type"))
                }
                out.append(AcoustIDMatch(score: score, recordingID: id, title: rec.str("title"), artists: MusicBrainzParser.creditList(rec.arr("artists").map { ["artist": $0] }), releaseGroups: rgs))
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// `apiKey` is the application key from acoustid.org (free). Returns matches best-first.
    func lookup(_ fp: Fingerprint, apiKey: String) async throws -> [AcoustIDMatch] {
        guard !apiKey.isEmpty else { throw AureonError.message("Add an AcoustID application key in Connect to identify untagged files.") }
        var form = URLComponents()
        form.queryItems = [("client", apiKey), ("format", "json"), ("meta", "recordings releasegroups"), ("duration", String(fp.duration)), ("fingerprint", fp.value)].map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: endpoint); req.httpMethod = "POST"
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); req.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        await limiter.wait()
        let (d, status) = try await http.send(req)
        guard status == 200 else { throw NetworkError.status(status, "acoustid lookup") }
        return try Self.parse(d)
    }
}
