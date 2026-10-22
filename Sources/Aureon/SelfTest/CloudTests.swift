import Foundation
import AVFoundation

/// An S3 server in memory: verifies every signature, serves ranges and paginated listings, and can be slowed down or made to fail.
final class FakeS3: HTTPClient, @unchecked Sendable {
    struct Object { var data: Data; var modified: Date }
    let bucket: String, accessKey: String, secret: String, region: String
    private let lock = NSLock()
    private(set) var objects: [String: Object] = [:]
    private(set) var log: [String] = []
    var latency = 0.0
    var failNext = 0
    var pageSize = 1000
    private var active = 0
    private(set) var maxActive = 0
    private(set) var rangeBytes = 0

    init(bucket: String = "music", accessKey: String = "AKIATEST", secret: String = "s3cr3t/KEY+test", region: String = "us-west-004") {
        self.bucket = bucket; self.accessKey = accessKey; self.secret = secret; self.region = region
    }
    func put(_ key: String, _ data: Data, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) { lock.lock(); objects[key] = Object(data: data, modified: modified); lock.unlock() }
    func delete(_ key: String) { lock.lock(); objects[key] = nil; lock.unlock() }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return log.count }
    var gets: Int { lock.lock(); defer { lock.unlock() }; return log.filter { $0.hasPrefix("GET /music/") }.count }
    func reset() { lock.lock(); log = []; maxActive = 0; rangeBytes = 0; lock.unlock() }
    var bytesServed: Int { lock.lock(); defer { lock.unlock() }; return rangeBytes }

    private func xml(_ status: Int, _ code: String, _ msg: String) -> (Data, Int) {
        (Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code><Message>\(msg)</Message></Error>".utf8), status)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); active += 1; maxActive = max(maxActive, active); log.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")" + (request.url?.query.map { "?" + $0 } ?? "")); let fail = failNext > 0; if fail { failNext -= 1 }; lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if fail { return xml(503, "SlowDown", "Reduce your request rate") }
        guard let url = request.url, let auth = request.value(forHTTPHeaderField: "Authorization") else { return xml(403, "AccessDenied", "no signature") }

        // recompute the signature from what arrived
        guard let credRange = auth.range(of: "Credential="), let sigRange = auth.range(of: "Signature="), let shRange = auth.range(of: "SignedHeaders=") else { return xml(400, "AuthorizationHeaderMalformed", "bad header") }
        let cred = auth[credRange.upperBound...].prefix { $0 != "," }
        let parts = cred.split(separator: "/").map(String.init)
        guard parts.count == 5, parts[0] == accessKey else { return xml(403, "InvalidAccessKeyId", "unknown key") }
        let signedNames = auth[shRange.upperBound...].prefix { $0 != "," }.split(separator: ";").map(String.init)
        let theirs = String(auth[sigRange.upperBound...].prefix { $0 != "," && $0 != " " })
        var headers: [(String, String)] = []
        for n in signedNames { headers.append((n, request.value(forHTTPHeaderField: n) ?? "")) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = (comps.percentEncodedQueryItems ?? []).map { ($0.name.removingPercentEncoding ?? "", ($0.value ?? "").removingPercentEncoding ?? "") }
        let canon = SigV4.canonicalRequest(method: request.httpMethod ?? "GET", path: comps.percentEncodedPath, query: q, headers: headers, payloadHash: request.value(forHTTPHeaderField: "x-amz-content-sha256") ?? "")
        let amz = request.value(forHTTPHeaderField: "x-amz-date") ?? ""
        let mine = SigV4.signature(canonical: canon.text, region: parts[2], service: parts[3], secret: secret, stamp: (amz, parts[1]))
        guard mine.signature == theirs else { return xml(403, "SignatureDoesNotMatch", "The request signature we calculated does not match") }
        guard parts[2] == region else { return xml(400, "AuthorizationHeaderMalformed", "the region \(parts[2]) is wrong; expecting \(region)") }

        let segs = comps.percentEncodedPath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? "" }
        let rest = comps.percentEncodedPath.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard segs.count >= 2 || !rest.isEmpty, (rest.first.map(String.init)?.removingPercentEncoding) == bucket else { return xml(404, "NoSuchBucket", "The specified bucket does not exist") }
        let key = rest.count > 1 ? (String(rest[1]).removingPercentEncoding ?? "") : ""

        lock.lock(); let snapshot = objects; lock.unlock()
        if key.isEmpty {
            func qv(_ n: String) -> String? { q.first { $0.0 == n }?.1 }
            let prefix = qv("prefix") ?? "", delimiter = qv("delimiter"), start = Int(qv("continuation-token") ?? "0") ?? 0
            let max = min(Int(qv("max-keys") ?? "1000") ?? 1000, pageSize)
            var keys = snapshot.keys.filter { $0.hasPrefix(prefix) }.sorted()
            var folders = Set<String>()
            if let d = delimiter {
                keys = keys.filter { k in
                    let tail = k.dropFirst(prefix.count)
                    if let r = tail.range(of: d) { folders.insert(prefix + tail[..<r.upperBound]); return false }
                    return true
                }
            }
            let page = Array(keys.dropFirst(start).prefix(max)), more = start + page.count < keys.count
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(bucket)</Name><Prefix>\(prefix)</Prefix><KeyCount>\(page.count)</KeyCount><IsTruncated>\(more)</IsTruncated>"
            if more { body += "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" }
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
            for k in page { let o = snapshot[k]!; body += "<Contents><Key>\(esc(k))</Key><LastModified>\(f.string(from: o.modified))</LastModified><ETag>&quot;abc&quot;</ETag><Size>\(o.data.count)</Size></Contents>" }
            for fo in folders.sorted() { body += "<CommonPrefixes><Prefix>\(esc(fo))</Prefix></CommonPrefixes>" }
            body += "</ListBucketResult>"
            return (Data(body.utf8), 200)
        }
        guard let o = snapshot[key] else { return xml(404, "NoSuchKey", "The specified key does not exist.") }
        if let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let nums = r.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard nums.count == 2, nums[0] < o.data.count else { return xml(416, "InvalidRange", "range") }
            let slice = o.data.subdata(in: nums[0]..<min(nums[1] + 1, o.data.count))
            lock.lock(); rangeBytes += slice.count; lock.unlock()
            return (slice, 206)
        }
        lock.lock(); rangeBytes += o.data.count; lock.unlock()
        return (o.data, 200)
    }
}

/// Bytes in memory behind a bit of network behaviour.
final class SlowBytes: RangeFetcher, @unchecked Sendable {
    let data: Data
    var size: Int64 { Int64(data.count) }
    var latency: Double
    var failures: Int                 // fail this many calls (any chunk) before working
    var failAlways = false
    var hang = false
    private let lock = NSLock()
    private(set) var calls = 0, active = 0, maxActive = 0
    private(set) var ranges: [Int64] = []
    init(_ d: Data, latency: Double = 0, failures: Int = 0) { data = d; self.latency = latency; self.failures = failures }
    func fetch(offset: Int64, length: Int) async throws -> Data {
        lock.lock(); calls += 1; active += 1; maxActive = max(maxActive, active); ranges.append(offset)
        let fail = failAlways || failures > 0; if failures > 0 { failures -= 1 }
        let h = hang
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if h { try await Task.sleep(nanoseconds: 30_000_000_000) }
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if fail { throw URLError(.networkConnectionLost) }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }
}

struct CloudTests {
    let dir = tempDir("cloud")

    private func bytes(_ n: Int, seed: UInt64 = 1) -> Data {
        var x = seed, out = Data(count: n)
        out.withUnsafeMutableBytes { p in for i in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; p[i] = UInt8(truncatingIfNeeded: x >> 56) } }
        return out
    }

    // MARK: signing

    func awsPublishedVectors() {
        // Examples from "Signature Calculations for the Authorization Header" in the Amazon S3 documentation
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let stamp = ("20130524T000000Z", "20130524")
        let c1 = SigV4.canonicalRequest(method: "GET", path: "/test.txt", query: [], headers: [("host", "examplebucket.s3.amazonaws.com"), ("range", "bytes=0-9"), ("x-amz-content-sha256", empty), ("x-amz-date", stamp.0)], payloadHash: empty)
        expect(SigV4.sha256(Data(c1.text.utf8)) == "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972", "canonical request hash (GET object)")
        expect(SigV4.signature(canonical: c1.text, region: "us-east-1", service: "s3", secret: secret, stamp: stamp).signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", "signature (GET object)")
        let c2 = SigV4.canonicalRequest(method: "GET", path: "/", query: [("max-keys", "2"), ("prefix", "J")], headers: [("host", "examplebucket.s3.amazonaws.com"), ("x-amz-content-sha256", empty), ("x-amz-date", stamp.0)], payloadHash: empty)
        expect(SigV4.signature(canonical: c2.text, region: "us-east-1", service: "s3", secret: secret, stamp: stamp).signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", "signature (list objects)")

        // the client produces the same Authorization header for the same request
        final class Capture: HTTPClient, @unchecked Sendable { var last: URLRequest?; func send(_ r: URLRequest) async throws -> (Data, Int) { last = r; return (Data(), 206) } }
        let cap = Capture()
        let client = S3Client(config: S3Config(endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1", bucket: "examplebucket", pathStyle: false), credentials: S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: secret), http: cap)
        client.now = { Date(timeIntervalSince1970: 1_369_353_600) }
        _ = try! runAsync { try await client.get(key: "test.txt", range: 0..<10) }.get()
        let auth = cap.last?.value(forHTTPHeaderField: "Authorization") ?? ""
        expect(auth == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", auth)
        expect(cap.last?.url?.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt" && cap.last?.value(forHTTPHeaderField: "Range") == "bytes=0-9", "\(cap.last?.url?.absoluteString ?? "")")
    }

    func keysAreEncodedTheAwsWay() {
        expect(SigV4.encode("a b/é+(1)~.-_", keepSlash: true) == "a%20b/%C3%A9%2B%281%29~.-_", SigV4.encode("a b/é+(1)~.-_", keepSlash: true))
        expect(SigV4.encode("a/b") == "a%2Fb" && SigV4.encode("ü*") == "%C3%BC%2A")
        let c = S3Client(config: S3Config(endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, region: "us-west-004", bucket: "my music", pathStyle: true), credentials: S3Credentials(accessKey: "k", secretKey: "s"), http: FakeS3())
        expect(c.url(key: "Artist & Co/01 Café + Bar (live).flac").absoluteString == "https://s3.us-west-004.backblazeb2.com/my%20music/Artist%20%26%20Co/01%20Caf%C3%A9%20%2B%20Bar%20%28live%29.flac", c.url(key: "Artist & Co/01 Café + Bar (live).flac").absoluteString)
        // a server that verifies signatures over those awkward names accepts them
        let s3 = FakeS3(bucket: "my music"); s3.put("Artist & Co/01 Café + Bar (live).flac", Data("hello".utf8))
        let client = S3Client(config: c.config, credentials: S3Credentials(accessKey: s3.accessKey, secretKey: s3.secret), http: s3)
        let got = try! runAsync { try await client.get(key: "Artist & Co/01 Café + Bar (live).flac", range: 1..<4) }.get()
        expect(String(decoding: got, as: UTF8.self) == "ell", "range read through a signed request")
    }

    func listingsPageAndMapErrors() {
        let s3 = FakeS3(); s3.pageSize = 400
        for i in 0..<1000 { s3.put("Jazz/Album \(i / 100)/\(String(format: "%04d", i)).flac", Data([1])) }
        s3.put("Rock/x.flac", Data([1, 2])); s3.put("Rock/readme.txt", Data("t".utf8))
        let client = S3Client(config: S3Config(endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, region: "us-west-004", bucket: "music"), credentials: S3Credentials(accessKey: s3.accessKey, secretKey: s3.secret), http: s3)
        let all = try! runAsync { try await client.listAll(prefix: "") }.get()
        expect(all.count == 1002 && all.first?.key == "Jazz/Album 0/0000.flac", "\(all.count) keys over 3 pages")
        expect(s3.log.filter { $0.contains("continuation-token") }.count == 2, "followed the continuation tokens: \(s3.log.count) requests")
        let top = try! runAsync { try await client.list(prefix: "") }.get()
        expect(top.folders == ["Jazz/", "Rock/"] && top.objects.isEmpty, "\(top.folders)")
        let rock = try! runAsync { try await client.list(prefix: "Rock/") }.get()
        expect(rock.objects.map(\.key) == ["Rock/readme.txt", "Rock/x.flac"] && rock.objects[1].size == 2 && rock.objects[0].modified == Date(timeIntervalSince1970: 1_700_000_000), "sizes and dates are read")
        let st = try! runAsync { try await client.stat(key: "Rock/x.flac") }.get()
        expect(st?.size == 2, "stat finds one object by key")
        expect((try! runAsync { try await client.stat(key: "Rock/x") }.get()) == nil, "a prefix is not an object")

        func failure(_ edit: (inout S3Credentials, inout S3Config) -> Void) -> String {
            var cr = S3Credentials(accessKey: s3.accessKey, secretKey: s3.secret), cf = client.config; edit(&cr, &cf)
            if case .failure(let e) = runAsync({ try await S3Client(config: cf, credentials: cr, http: s3).list(prefix: "") }) { return e.localizedDescription }
            return "no error"
        }
        expect(failure { c, _ in c.secretKey = "wrong" }.contains("signature"), failure { c, _ in c.secretKey = "wrong" })
        expect(failure { c, _ in c.accessKey = "nope" }.contains("access key"), failure { c, _ in c.accessKey = "nope" })
        expect(failure { _, f in f.bucket = "ghost" }.contains("no bucket"), failure { _, f in f.bucket = "ghost" })
        expect(failure { _, f in f.region = "eu-central-1" }.contains("different region"), failure { _, f in f.region = "eu-central-1" })
    }

    // MARK: the chunk reader

    func readerReturnsTheRightBytes() {
        let data = bytes(5_000_000)
        var cfg = ChunkedReader.Config(); cfg.chunkSize = 256 << 10
        let r = ChunkedReader(fetcher: SlowBytes(data), config: cfg)
        var buf = [UInt8](repeating: 0, count: 700_000)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            let off = Int.random(in: 0..<data.count, using: &rng), len = Int.random(in: 1...buf.count, using: &rng)
            let n = try! buf.withUnsafeMutableBytes { try r.read(offset: Int64(off), length: len, into: $0.baseAddress!) }
            expect(n == min(len, data.count - off) && Data(buf[0..<n]) == data.subdata(in: off..<(off + n)), "random read at \(off) len \(len)")
        }
        expect((try! buf.withUnsafeMutableBytes { try r.read(offset: Int64(data.count), length: 10, into: $0.baseAddress!) }) == 0, "reading at the end returns nothing")
        expect((try! buf.withUnsafeMutableBytes { try r.read(offset: Int64(data.count - 5), length: 100, into: $0.baseAddress!) }) == 5, "a read crossing the end is cut")
        // several threads at once
        let group = DispatchGroup()
        let bad = NSLock(); var mismatches = 0
        for t in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                var b = [UInt8](repeating: 0, count: 300_000)
                for k in 0..<20 {
                    let off = (t * 700_001 + k * 123_457) % (data.count - 300_000)
                    let n = try! b.withUnsafeMutableBytes { try r.read(offset: Int64(off), length: 300_000, into: $0.baseAddress!) }
                    if Data(b[0..<n]) != data.subdata(in: off..<(off + n)) { bad.lock(); mismatches += 1; bad.unlock() }
                }
                group.leave()
            }
        }
        group.wait()
        expect(mismatches == 0, "\(mismatches) wrong reads under concurrency")
    }

    func readAheadHidesTheLatency() {
        let data = bytes(12_000_000, seed: 5)
        func play(ahead: Int, inFlight: Int) -> (stall: Double, stats: ChunkedReader.Stats) {
            var cfg = ChunkedReader.Config(); cfg.chunkSize = 256 << 10; cfg.defaultAhead = ahead; cfg.minAhead = ahead; cfg.maxInFlight = inFlight
            let f = SlowBytes(data, latency: 0.03)
            let r = ChunkedReader(fetcher: f, config: cfg)
            var buf = [UInt8](repeating: 0, count: 64 << 10)
            var off = 0
            // the decoder asks for 64 KiB every 4 ms (16 MB/s): far faster than any audio, slower than the network with read-ahead
            while off < 3_000_000 {
                let n = try! buf.withUnsafeMutableBytes { try r.read(offset: Int64(off), length: 64 << 10, into: $0.baseAddress!) }
                off += n; Thread.sleep(forTimeInterval: 0.004)
            }
            return (r.stats.stallSeconds, r.stats)
        }
        let lazy = play(ahead: 0, inFlight: 1), smart = play(ahead: 12, inFlight: 4)
        expect(lazy.stall > 0.25, "without read-ahead every chunk waits for the network: \(lazy.stall) s")
        expect(smart.stall < 0.12, "with read-ahead only the first chunk waits: \(smart.stall) s")
        expect(smart.stats.hits > smart.stats.misses * 2, "mostly hits: \(smart.stats)")
        expect(smart.stats.maxInFlight <= 4, "never more than 4 requests at once: \(smart.stats.maxInFlight)")
    }

    func lookaheadFollowsTheBitrate() {
        var cfg = ChunkedReader.Config(); cfg.chunkSize = 1 << 20
        let r = ChunkedReader(fetcher: SlowBytes(Data(count: 100)), config: cfg)
        r.setBitrate(bytesPerSecond: 16_000)                                     // 128 kbps MP3: 30 s is under 1 MB
        expect(r.lookahead == cfg.minAhead, "\(r.lookahead)")
        r.setBitrate(bytesPerSecond: 1_100_000)                                  // 24-bit / 96 kHz stereo FLAC
        expect(r.lookahead == 32, "\(r.lookahead)")
        r.setBitrate(bytesPerSecond: 80_000_000)
        expect(r.lookahead == cfg.maxAhead, "capped at \(cfg.maxAhead)")
    }

    func cacheStaysBounded() {
        let data = bytes(24_000_000, seed: 9)
        var cfg = ChunkedReader.Config(); cfg.chunkSize = 256 << 10; cfg.maxCacheBytes = 3 << 20; cfg.defaultAhead = 4
        let r = ChunkedReader(fetcher: SlowBytes(data), config: cfg)
        r.warm(head: 2, tail: 1)
        var buf = [UInt8](repeating: 0, count: 128 << 10), off = 0
        while off < data.count {
            let n = try! buf.withUnsafeMutableBytes { try r.read(offset: Int64(off), length: 128 << 10, into: $0.baseAddress!) }
            expect(Data(buf[0..<n]) == data.subdata(in: off..<(off + n)))
            off += n
        }
        expect(r.cachedBytesNow <= (3 << 20) + 8 * (256 << 10), "cache holds \(r.cachedBytesNow) bytes")
        expect(r.stats.evictions > 50, "old chunks were dropped: \(r.stats.evictions)")
        expect(r.isCached(offset: 0, length: 512 << 10) && r.isCached(offset: Int64(data.count) - 1000, length: 1000), "the header and the tail stay: they are re-read on every seek or reopen")
        expect(!r.isCached(offset: 10_000_000, length: 1000))
    }

    func warmPreparesTheNextTrack() {
        let data = bytes(8_000_000, seed: 3)
        var cfg = ChunkedReader.Config(); cfg.chunkSize = 1 << 20
        let f = SlowBytes(data, latency: 0.02)
        let r = ChunkedReader(fetcher: f, config: cfg)
        r.warm(head: 3, tail: 1)
        let t0 = Date()
        while !(r.isCached(offset: 0, length: 3 << 20) && r.isCached(offset: Int64(data.count) - 100, length: 100)), Date().timeIntervalSince(t0) < 3 { Thread.sleep(forTimeInterval: 0.01) }
        expect(r.isCached(offset: 0, length: 3 << 20) && r.isCached(offset: Int64(data.count) - 100, length: 100), "warm loaded the first three chunks and the last one")
        let before = f.calls
        var b = [UInt8](repeating: 0, count: 2 << 20)
        let started = Date()
        _ = try! b.withUnsafeMutableBytes { try r.read(offset: 0, length: 2 << 20, into: $0.baseAddress!) }
        expect(Date().timeIntervalSince(started) < 0.015 && r.stats.stallSeconds == 0, "the start of the track plays with no wait")
        _ = before
    }

    func networkTroubleIsRiddenOut() {
        let data = bytes(3_000_000, seed: 7)
        var cfg = ChunkedReader.Config(); cfg.chunkSize = 512 << 10; cfg.retryDelay = 0.01; cfg.retries = 4; cfg.readTimeout = 1.0
        let flaky = SlowBytes(data, failures: 6)
        let r = ChunkedReader(fetcher: flaky, config: cfg)
        var b = [UInt8](repeating: 0, count: 3_000_000)
        let n = try! b.withUnsafeMutableBytes { try r.read(offset: 0, length: 3_000_000, into: $0.baseAddress!) }
        expect(n == 3_000_000 && Data(b) == data && r.stats.retries >= 6, "six failed requests were retried transparently: \(r.stats.retries) retries")

        let dead = SlowBytes(data); dead.failAlways = true
        let r2 = ChunkedReader(fetcher: dead, config: cfg)
        do { _ = try b.withUnsafeMutableBytes { try r2.read(offset: 0, length: 1000, into: $0.baseAddress!) }; expect(false, "should fail") } catch { expect(!"\(error)".isEmpty) }
        dead.failAlways = false
        let m = try? b.withUnsafeMutableBytes { try r2.read(offset: 0, length: 1000, into: $0.baseAddress!) }
        expect(m == 1000 && Data(b[0..<1000]) == data.prefix(1000), "after a failure the next read tries again instead of remembering the error")

        let stuck = SlowBytes(data); stuck.hang = true
        var c2 = cfg; c2.readTimeout = 0.3
        let r3 = ChunkedReader(fetcher: stuck, config: c2)
        let t0 = Date()
        do { _ = try b.withUnsafeMutableBytes { try r3.read(offset: 0, length: 1000, into: $0.baseAddress!) }; expect(false, "should time out") } catch { expect(error.localizedDescription.contains("too long"), error.localizedDescription) }
        expect(Date().timeIntervalSince(t0) < 1.5, "gave up after the timeout, not after the server")

        let slow = SlowBytes(data, latency: 5)
        let r4 = ChunkedReader(fetcher: slow, config: cfg)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { r4.close() }
        do { _ = try b.withUnsafeMutableBytes { try r4.read(offset: 0, length: 1000, into: $0.baseAddress!) }; expect(false, "should be closed") } catch { expect(error.localizedDescription.contains("closed"), error.localizedDescription) }
    }

    // MARK: decoding from the bucket

    private func audioFiles() -> (flac: URL, m4a: URL, alac: URL) {
        let flac = dir.appendingPathComponent("song.flac")
        do {
            let f = try! AVAudioFile(forWriting: flac, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatInt16, interleaved: true)
            let n = 44_100 * 6
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!; buf.frameLength = AVAudioFrameCount(n)
            var x: UInt64 = 11
            for i in 0..<n { for c in 0..<2 { x = x &* 6364136223846793005 &+ 1; buf.int16ChannelData![0][2 * i + c] = Int16(truncatingIfNeeded: Int(x >> 50) - 8192 + Int(6000 * sin(Double(i) * 0.03))) } }
            try! f.write(from: buf)
        }
        try! FLACTagWriter.write(path: flac.path, comments: [("TITLE", "Cloud Song"), ("ARTIST", "The Buckets"), ("ALBUM", "Remote"), ("TRACKNUMBER", "1"), ("DATE", "2020")],
                                 picture: .init(data: Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3, 4, 5, 6, 7]), mime: "image/png"))
        let m4a = dir.appendingPathComponent("song.m4a"), alac = dir.appendingPathComponent("song-lossless.m4a")
        expect(Transcoder.transcode(TranscodeJob(source: flac, destination: m4a), options: TranscodeOptions(format: .aac)).ok)
        expect(Transcoder.transcode(TranscodeJob(source: flac, destination: alac), options: TranscodeOptions(format: .alac)).ok)
        return (flac, m4a, alac)
    }

    private func samples(_ f: LosslessFile, from: Int64 = 0) -> [Int32] {
        f.seek(to: from)
        var out: [Int32] = [], b = [Int32](repeating: 0, count: 4096 * f.info.channels)
        while true { let n = f.read(into: &b, frames: 4096); if n == 0 { break }; out += b[0..<(n * f.info.channels)] }
        return out
    }

    func remoteFilesDecodeIdentically() {
        let files = audioFiles()
        for (name, url) in [("FLAC", files.flac), ("AAC", files.m4a), ("ALAC", files.alac)] {
            let data = try! Data(contentsOf: url)
            var cfg = ChunkedReader.Config(); cfg.chunkSize = 64 << 10
            let fetch = SlowBytes(data, latency: 0.002)
            let reader = ChunkedReader(fetcher: fetch, config: cfg)
            let remote = try! RemoteAudioHandle.open(reader: reader, fileExtension: url.pathExtension)
            let local = try! LosslessFile(path: url.path)
            expect(remote.info == local.info, "\(name): same stream info \(remote.info)")
            expect(samples(remote) == samples(local), "\(name): every sample identical to the local file")
            let seekTo = local.info.totalFrames / 3
            expect(samples(remote, from: seekTo) == samples(local, from: seekTo), "\(name): seeking works")
            expect(fetch.ranges.allSatisfy { $0 % Int64(64 << 10) == 0 } && reader.stats.bytesFetched <= data.count + (64 << 10), "\(name): the file was fetched once, in chunks (\(reader.stats.bytesFetched) of \(data.count) bytes)")
        }
        let junk = SlowBytes(bytes(100_000))
        if case .failure = Result(catching: { try RemoteAudioHandle.open(reader: ChunkedReader(fetcher: junk), fileExtension: "flac") }) {} else { expect(false, "a file that is not audio must fail to open") }
        let gone = SlowBytes(bytes(100_000)); gone.failAlways = true
        var c = ChunkedReader.Config(); c.retries = 0
        if case .failure(let e) = Result(catching: { try RemoteAudioHandle.open(reader: ChunkedReader(fetcher: gone, config: c), fileExtension: "flac") }) { expect(!e.localizedDescription.isEmpty, "\(e)") } else { expect(false, "an unreachable file must fail to open") }
    }

    // MARK: profiles, import and playback

    private func registry(_ s3: FakeS3, secret: String? = nil) -> (CloudRegistry, CloudProfile) {
        let reg = CloudRegistry()
        reg.secrets = MemorySecretStore(); reg.http = s3
        reg.defaults = UserDefaults(suiteName: "aureon.cloudtest.\(UUID().uuidString.prefix(6))")!
        var p = CloudProfile(); p.name = "Test B2"; p.provider = .backblaze; p.region = s3.region; p.endpoint = CloudProvider.backblaze.endpoint(region: s3.region); p.bucket = s3.bucket; p.accessKey = s3.accessKey
        reg.save(p, secret: secret ?? s3.secret)
        return (reg, p)
    }

    func importingABucket() {
        let files = audioFiles()
        let s3 = FakeS3()
        let flacData = try! Data(contentsOf: files.flac), m4aData = try! Data(contentsOf: files.m4a)
        s3.put("Albums/Remote/01 Cloud Song.flac", flacData)
        s3.put("Albums/Remote/02 Cloud Song AAC.m4a", m4aData)
        s3.put("Albums/Remote/cover.jpg", Data([1, 2, 3])); s3.put("Albums/Remote/notes.txt", Data("x".utf8))
        s3.put("Other/Café & Co/03 Lossless.m4a", try! Data(contentsOf: files.alac))
        let (reg, p) = registry(s3)
        let lib = try! LibraryStore()
        let r1 = try! CloudImporter.run(profile: p, registry: reg, store: lib)
        expect(r1.scanned == 3 && r1.added == 3 && r1.failed == 0, "\(r1)")
        let t = lib.track(path: CloudPath.make(profile: p.id, key: "Albums/Remote/01 Cloud Song.flac"))
        expect(t?.title == "Cloud Song" && t?.artistLine == "The Buckets" && t?.releaseTitle == "Remote" && t?.codec == "FLAC" && t?.sampleRate == 44_100 && abs((t?.duration ?? 0) - 6) < 0.05 && t?.year == 2020, "\(String(describing: t))")
        let aac = lib.track(path: CloudPath.make(profile: p.id, key: "Albums/Remote/02 Cloud Song AAC.m4a"))
        expect(aac?.title == "Cloud Song" && aac?.artistLine == "The Buckets", "tags of an MP4 file are found through its moov box: \(String(describing: aac?.title))")
        let importBytes = s3.bytesServed
        expect(importBytes < (flacData.count + m4aData.count + (try! Data(contentsOf: files.alac)).count) * 2, "the import did not download everything several times over: \(importBytes) bytes")

        // nothing changed: only the listing is requested
        s3.reset()
        let r2 = try! CloudImporter.run(profile: p, registry: reg, store: lib)
        expect(r2.skipped == 3 && r2.added == 0 && s3.gets == 0, "\(r2) with \(s3.gets) object requests")
        // one changed, one removed
        s3.put("Albums/Remote/01 Cloud Song.flac", flacData, modified: Date(timeIntervalSince1970: 1_800_000_000))
        s3.delete("Other/Café & Co/03 Lossless.m4a")
        let r3 = try! CloudImporter.run(profile: p, registry: reg, store: lib)
        expect(r3.updated == 1 && r3.skipped == 1 && r3.removed == 1, "\(r3)")
        expect(lib.track(path: CloudPath.make(profile: p.id, key: "Other/Café & Co/03 Lossless.m4a")) == nil)

        // credentials problems come out as sentences
        let (reg2, p2) = registry(s3, secret: "wrong")
        do { _ = try CloudImporter.run(profile: p2, registry: reg2, store: lib); expect(false, "bad secret must throw") } catch { expect(error.localizedDescription.contains("signature"), error.localizedDescription) }
        reg2.secrets.set(nil, for: p2.secretAccount)
        do { _ = try CloudImporter.run(profile: p2, registry: reg2, store: lib); expect(false, "missing secret must throw") } catch { expect(error.localizedDescription.contains("secret key"), error.localizedDescription) }
    }

    func cloudTracksPlayLikeFiles() {
        let files = audioFiles()
        let s3 = FakeS3(); s3.latency = 0.005
        s3.put("a/song.flac", try! Data(contentsOf: files.flac))
        s3.put("b/next.flac", try! Data(contentsOf: files.flac))
        let (reg, p) = registry(s3)
        let old = CloudRegistry.shared
        // the player and the analysers use the shared registry
        CloudRegistry.shared.secrets = reg.secrets; CloudRegistry.shared.http = s3; CloudRegistry.shared.defaults = reg.defaults
        CloudRegistry.shared.save(p, secret: s3.secret)
        defer { CloudRegistry.shared.remove(p.id); _ = old }
        let path = CloudPath.make(profile: p.id, key: "a/song.flac"), path2 = CloudPath.make(profile: p.id, key: "b/next.flac")
        expect(CloudPath.parse(path)?.key == "a/song.flac" && CloudPath.parse(path)?.profile == p.id && CloudPath.parse("/local/file.flac") == nil)

        // straight through the player: bit-identical to the same file on disk
        let local = samples(try! LosslessFile(path: files.flac.path))
        let sink = RecordingSink(speed: 20)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let pl = Player()
        pl.setQueue([path, path2]); pl.start(options: o)
        _ = pl.waitUntilFinished(timeout: 20)
        let got = sink.samples
        let lead = got.firstIndex { $0 != 0 } ?? 0
        expect(pl.status.finished && pl.status.errors.isEmpty, "errors: \(pl.status.errors)")
        expect(got.count >= local.count * 2 && Array(got[lead..<(lead + local.count)]) == local, "the first track is bit-perfect from the bucket")
        expect(Array(got[(lead + local.count)..<(lead + local.count * 2)]) == local, "and the second follows with no gap and no change")

        // analysers read cloud tracks too
        let r128 = R128.analyze(path: path), r128Local = R128.analyze(path: files.flac.path)
        expect(r128 != nil && abs((r128?.integratedLUFS ?? 0) - (r128Local?.integratedLUFS ?? 1)) < 1e-9, "loudness analysis from the bucket equals the local one")
        let pic = runAsync { await MetadataEngine.artwork(path: path) }
        if case .success(let d) = pic { expect(d?.count == 12, "cover art is read from the start of the remote file") } else { expect(false, "artwork") }
        if case .success(let t) = runAsync({ await MetadataEngine.load(path: path) }) { expect(t.title == "Cloud Song" && t.artist == "The Buckets", "\(t)") } else { expect(false, "tags") }

        // a vanished file is an error, not a hang
        s3.delete("a/song.flac")
        CloudRegistry.shared.remove("zzz")
        let missing = CloudPath.make(profile: p.id, key: "a/nothing.flac")
        expect((try? openLossless(path: missing)) == nil, "a missing object cannot be opened")
        expect((try? openLossless(path: CloudPath.make(profile: "unknown", key: "x.flac"))) == nil, "neither can one from a library that was removed")
    }
}
