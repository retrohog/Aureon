import Foundation

/// Something that can return a byte range of a remote object.
protocol RangeFetcher: Sendable {
    var size: Int64 { get }
    func fetch(offset: Int64, length: Int) async throws -> Data
}

struct S3ObjectFetcher: RangeFetcher {
    let client: S3Client
    let key: String
    let size: Int64
    func fetch(offset: Int64, length: Int) async throws -> Data { try await client.get(key: key, range: offset..<(offset + Int64(length))) }
}

/// A random-access view of a remote file for the audio decoder: fixed-size chunks, fetched in parallel ahead of the playhead,
/// kept in a bounded cache. `read` blocks the (non-realtime) decoding thread until the bytes are there, so playback never sees a hole.
///
/// What makes it dropout-free rather than merely lazy:
///  - the look-ahead is sized in *seconds of audio* (`setBitrate`), so a 24/192 file gets a deeper pipeline than a 128 kbps one;
///  - several chunks are in flight at once, so one slow request does not stall the stream;
///  - a failed request is retried with back-off before the decoder ever hears about it;
///  - the first and last chunks stay cached (headers, and the MP4 `moov` box that lives at the end), and `warm` loads them for
///    the next track while the current one is still playing, which is what keeps the gap between tracks closed.
final class ChunkedReader: @unchecked Sendable {
    struct Config: Equatable {
        var chunkSize = 1 << 20
        var maxCacheBytes = 128 << 20
        var minAhead = 3, maxAhead = 48, defaultAhead = 6
        var lookaheadSeconds = 30.0
        var maxInFlight = 4
        var retries = 4
        var retryDelay = 0.25
        var readTimeout = 60.0
    }
    struct Stats: Equatable {
        var requests = 0, retries = 0, hits = 0, misses = 0, evictions = 0, maxInFlight = 0
        var bytesFetched = 0
        var stallSeconds = 0.0
    }
    enum ReadError: LocalizedError {
        case closed, timeout
        case failed(Error)
        var errorDescription: String? {
            switch self { case .closed: "The remote file was closed."; case .timeout: "The storage service took too long to answer."; case .failed(let e): e.localizedDescription }
        }
    }

    private enum Slot { case loading, ready(Data), failed(Error) }

    let config: Config
    let size: Int64
    private let fetcher: RangeFetcher
    private let cond = NSCondition()
    private var slots: [Int: Slot] = [:]
    private var stamp: [Int: UInt64] = [:]
    private var tick: UInt64 = 0
    private var inFlight = 0
    private var cachedBytes = 0
    private var closed = false
    private var lastEnd: Int64 = -1
    private var window = 0...0
    private var ahead: Int
    private var extra: [Int] = []
    private var pinned = Set<Int>()
    private var _stats = Stats()

    init(fetcher: RangeFetcher, config: Config = Config()) {
        self.fetcher = fetcher; self.config = config; size = fetcher.size; ahead = config.defaultAhead
    }
    deinit { close() }

    var chunkCount: Int { size == 0 ? 0 : Int((size + Int64(config.chunkSize) - 1) / Int64(config.chunkSize)) }
    var stats: Stats { cond.lock(); defer { cond.unlock() }; return _stats }
    var cachedBytesNow: Int { cond.lock(); defer { cond.unlock() }; return cachedBytes }
    var lookahead: Int { cond.lock(); defer { cond.unlock() }; return ahead }

    private func chunkRange(_ i: Int) -> (offset: Int64, length: Int) {
        let off = Int64(i) * Int64(config.chunkSize)
        return (off, Int(min(Int64(config.chunkSize), size - off)))
    }

    /// Tells the reader how fast the audio consumes bytes, so the look-ahead covers `lookaheadSeconds` of playback.
    func setBitrate(bytesPerSecond: Double) {
        guard bytesPerSecond > 0 else { return }
        cond.lock(); defer { cond.unlock() }
        ahead = max(config.minAhead, min(config.maxAhead, Int((bytesPerSecond * config.lookaheadSeconds / Double(config.chunkSize)).rounded(.up))))
    }

    func close() {
        cond.lock(); closed = true; slots = [:]; stamp = [:]; cachedBytes = 0; extra = []; cond.broadcast(); cond.unlock()
    }

    // MARK: fetching (all called with the lock held unless noted)

    private func startFetch(_ i: Int) {
        slots[i] = .loading
        inFlight += 1; _stats.requests += 1; _stats.maxInFlight = max(_stats.maxInFlight, inFlight)
        let (off, len) = chunkRange(i), f = fetcher, cfg = config
        Task.detached(priority: .userInitiated) { [weak self] in
            var attempt = 0
            while true {
                do {
                    let d = try await f.fetch(offset: off, length: len)
                    guard d.count == len else { throw NetworkError.badResponse("short answer: \(d.count) of \(len) bytes") }
                    self?.finished(i, .ready(d)); return
                } catch {
                    if attempt >= cfg.retries || self == nil || self?.isClosed == true { self?.finished(i, .failed(error)); return }
                    self?.noteRetry()
                    try? await Task.sleep(nanoseconds: UInt64(cfg.retryDelay * pow(2, Double(attempt)) * 1_000_000_000))
                    attempt += 1
                }
            }
        }
    }

    private var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return closed }
    private func noteRetry() { cond.lock(); _stats.retries += 1; cond.unlock() }

    private func finished(_ i: Int, _ result: Slot) {
        cond.lock(); defer { cond.unlock() }
        inFlight -= 1
        guard !closed else { cond.broadcast(); return }
        if case .ready(let d) = result { cachedBytes += d.count; _stats.bytesFetched += d.count }
        slots[i] = result; stamp[i] = tick; tick += 1
        evict()
        pump()
        cond.broadcast()
    }

    /// Starts the chunks the playhead will need next, nearest first, within the in-flight limit.
    private func pump() {
        guard !closed, chunkCount > 0 else { return }
        var wanted = Array(window.clamped(to: 0...(chunkCount - 1)))
        wanted += extra
        for i in wanted where i >= 0 && i < chunkCount && slots[i] == nil {
            if inFlight >= config.maxInFlight { break }
            startFetch(i)
        }
    }

    private func evict() {
        guard cachedBytes > config.maxCacheBytes else { return }
        let keep = (window.lowerBound - 1)...(window.upperBound + 1)
        let victims = slots.compactMap { (i, s) -> (Int, UInt64)? in
            if case .ready = s, !pinned.contains(i), !keep.contains(i) { return (i, stamp[i] ?? 0) }
            return nil
        }.sorted { $0.1 < $1.1 }
        for (i, _) in victims {
            guard cachedBytes > config.maxCacheBytes else { break }
            if case .ready(let d)? = slots[i] { cachedBytes -= d.count }
            slots[i] = nil; stamp[i] = nil; _stats.evictions += 1
        }
    }

    // MARK: public API

    /// Loads the first `head` chunks and the last `tail` chunks in the background and keeps them. Used for the next track in the queue.
    func warm(head: Int = 2, tail: Int = 1) {
        cond.lock(); defer { cond.unlock() }
        guard !closed, chunkCount > 0 else { return }
        let h = Array(0..<min(head, chunkCount)), t = Array(max(0, chunkCount - tail)..<chunkCount)
        extra = h + t.filter { !h.contains($0) }
        pinned.formUnion(extra)
        pump()
    }

    /// Whether the bytes are already here (a test hook, and how the UI shows "buffered").
    func isCached(offset: Int64, length: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard length > 0, offset >= 0, offset < size else { return true }
        let last = chunkIndex(min(size - 1, offset + Int64(length) - 1))
        for i in chunkIndex(offset)...last { guard case .ready? = slots[i] else { return false } }
        return true
    }

    private func chunkIndex(_ off: Int64) -> Int { Int(off / Int64(config.chunkSize)) }

    /// Copies up to `length` bytes starting at `offset` into `buffer`; returns how many (0 at the end of the file).
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        guard offset >= 0, offset < size, length > 0 else { return 0 }
        let len = Int(min(Int64(length), size - offset))
        let deadline = Date().addingTimeInterval(config.readTimeout)
        cond.lock(); defer { cond.unlock() }
        if closed { throw ReadError.closed }

        let first = chunkIndex(offset), last = chunkIndex(offset + Int64(len) - 1)
        let sequential = lastEnd >= 0 && offset >= lastEnd - 2 * Int64(config.chunkSize) && offset <= lastEnd + 2 * Int64(config.chunkSize)
        if !sequential { extra = extra.filter { pinned.contains($0) } }
        window = first...min(max(0, chunkCount - 1), last + ahead)

        var copied = 0
        while copied < len {
            let pos = offset + Int64(copied), i = chunkIndex(pos)
            var counted = false
            var data: Data?
            while data == nil {
                if closed { throw ReadError.closed }
                switch slots[i] {
                case .none:
                    if !counted { _stats.misses += 1; counted = true }
                    startFetch(i); pump()
                case .some(.failed(let e)):
                    slots[i] = nil
                    throw ReadError.failed(e)
                case .some(.loading):
                    if !counted { _stats.misses += 1; counted = true }
                    let left = deadline.timeIntervalSinceNow
                    if left <= 0 { throw ReadError.timeout }
                    let t0 = Date()
                    cond.wait(until: Date().addingTimeInterval(min(left, 0.5)))
                    _stats.stallSeconds += Date().timeIntervalSince(t0)
                case .some(.ready(let d)):
                    if !counted { _stats.hits += 1; counted = true }
                    stamp[i] = tick; tick += 1
                    data = d
                }
            }
            let d = data!
            let inChunk = Int(pos - Int64(i) * Int64(config.chunkSize)), n = min(d.count - inChunk, len - copied)
            let dest = buffer + copied
            cond.unlock()
            d.withUnsafeBytes { _ = memcpy(dest, $0.baseAddress! + inChunk, n) }
            cond.lock()
            copied += n
        }
        lastEnd = offset + Int64(len)
        pump()
        evict()
        return copied
    }
}
