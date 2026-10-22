import Foundation
import Accelerate
import NaturalLanguage

// Semantic Search: every song gets a short description ("Teardrop by Massive Attack. Album: Mezzanine (1998). Genre: Trip-Hop. Slow tempo,
// calm."), the description is turned into a vector by a text-embedding model, and a query finds the songs whose vectors point the same way.
// The index is built in the background the first time it is needed, cached on disk per model, and dropped from memory when the feature or
// the master switch is turned off.

/// Turns text into vectors. Implementations must return one vector per input, all of the same length.
protocol TextEmbedder: Sendable {
    /// Names the model, so vectors from different models never mix (the disk cache is kept per identity).
    var identity: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

enum SemanticSearchError: LocalizedError, Equatable {
    case modelUnavailable(String)
    case inconsistent
    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m): m
        case .inconsistent: "The embedding model returned vectors of different sizes."
        }
    }
}

/// Apple's on-device sentence embedding (NaturalLanguage). Runs on the CPU on any Mac, Intel included, and sends nothing anywhere.
final class OnDeviceEmbedder: TextEmbedder, @unchecked Sendable {
    let identity = "apple-nl-sentence-en-1"
    private let lock = NSLock()
    private var model: NLEmbedding?
    private var tried = false

    private func loaded() throws -> NLEmbedding {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        if !tried { tried = true; model = NLEmbedding.sentenceEmbedding(for: .english) }
        guard let model else { throw SemanticSearchError.modelUnavailable("The on-device text model is not available on this Mac. Switch Semantic Search to an API on the Intelligence page.") }
        return model
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let m = try loaded()
        let dim = m.dimension
        // NLEmbedding is not documented as thread-safe: one caller at a time
        lock.lock(); defer { lock.unlock() }
        return texts.map { t in
            guard let v = m.vector(for: t), v.count == dim else { return [Float](repeating: 0, count: dim) }
            return v.map { Float($0) }
        }
    }
}

/// Embeddings from the configured OpenAI-compatible API (OpenAI's text-embedding-3 models, or a custom server).
struct APIEmbedder: TextEmbedder {
    let client: OpenAICompatibleClient
    var identity: String { "api|\(client.config.baseURL)|\(client.config.embeddingModel)" }
    func embed(_ texts: [String]) async throws -> [[Float]] { try await client.embeddings(texts) }
}

/// The text that stands for a song in the index.
enum SemanticDescriptor {
    static func text(for t: TrackDTO, analysis a: DJTrackAnalysis?) -> String {
        var s = t.title
        let artist = t.artistLine
        if !artist.isEmpty { s += " by \(artist)" }
        s += "."
        if let album = t.releaseTitle, !album.isEmpty { s += " Album: \(album)" + (t.year.map { " (\($0))" } ?? "") + "." }
        else if let y = t.year { s += " Released \(y)." }
        if let w = t.workTitle, !w.isEmpty, w != t.title { s += " Work: \(w)." }
        if !t.genres.isEmpty { s += " Genre: \(t.genres.joined(separator: ", "))." }
        if let a {
            var mood: [String] = []
            if let b = a.bpm {
                mood.append(b < 80 ? "slow tempo, relaxed" : b < 108 ? "medium tempo" : b < 128 ? "upbeat" : "fast tempo, driving")
            }
            mood.append(a.energy < 0.3 ? "calm, quiet, mellow" : a.energy < 0.6 ? "moderate energy" : "energetic, intense")
            s += " " + mood.joined(separator: ", ").capitalizedFirst + "."
        }
        return s
    }
}

private extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

/// The vectors of a whole library, normalised, in one contiguous block. Immutable once built, so it can be searched from any thread.
final class SemanticIndex: Sendable {
    let dimension: Int
    let paths: [String]
    private let vectors: [Float]           // paths.count × dimension, row-major, each row of length 1 (or all zero)

    init(dimension: Int, paths: [String], normalized vectors: [Float]) {
        precondition(vectors.count == paths.count * dimension)
        self.dimension = dimension; self.paths = paths; self.vectors = vectors
    }

    var count: Int { paths.count }
    var bytes: Int { vectors.count * MemoryLayout<Float>.size }

    /// Cosine similarity of `query` with every song (one matrix-vector product), best first.
    func search(_ query: [Float], limit: Int, minScore: Float = 0.2, window: Float = 0.3) -> [(path: String, score: Float)] {
        guard query.count == dimension, count > 0, limit > 0 else { return [] }
        let q = Self.normalized(query)
        var scores = [Float](repeating: 0, count: count)
        vectors.withUnsafeBufferPointer { m in
            q.withUnsafeBufferPointer { v in
                scores.withUnsafeMutableBufferPointer { out in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), Int32(dimension), 1, m.baseAddress!, Int32(dimension), v.baseAddress!, 1, 0, out.baseAddress!, 1)
                }
            }
        }
        let best = scores.max() ?? 0
        let floor = max(minScore, best - window)
        var picked = scores.indices.filter { scores[$0] >= floor }
        picked.sort { scores[$0] > scores[$1] }
        return picked.prefix(limit).map { (paths[$0], scores[$0]) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
        n = n.squareRoot()
        guard n > 1e-12 else { return [Float](repeating: 0, count: v.count) }
        var inv = 1 / n, out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }
}

/// Vectors already computed, kept on disk per embedding model so the library is embedded once (and an API is paid once).
///
/// File: "AEMB", version, dimension, count (UInt32 each, little-endian), then per entry an 8-byte key (FNV-1a of path and description)
/// and `dimension` Float32 values.
struct EmbeddingCache {
    let url: URL

    init(directory: URL, identity: String) {
        url = directory.appendingPathComponent(String(Self.hash(identity), radix: 16) + ".vectors")
    }

    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    static func key(path: String, text: String) -> UInt64 { hash(path + "\u{0}" + text) }

    func load() -> (dimension: Int, vectors: [UInt64: [Float]])? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 16 else { return nil }
        func u32(_ o: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian }
        guard u32(0) == 0x424D_4541, u32(4) == 1 else { return nil }                    // "AEMB", version 1
        let dim = Int(u32(8)), n = Int(u32(12))
        let stride = 8 + dim * 4
        guard dim > 0, dim <= 16_384, d.count == 16 + n * stride else { return nil }
        var out: [UInt64: [Float]] = [:]
        out.reserveCapacity(n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = 16 + i * stride
                let k = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian
                var v = [Float](repeating: 0, count: dim)
                v.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(o + 8)..<(o + 8 + dim * 4)])) }
                out[k] = v
            }
        }
        return (dim, out)
    }

    func save(dimension: Int, entries: [(UInt64, [Float])]) {
        var d = Data(capacity: 16 + entries.count * (8 + dimension * 4))
        func put<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt32(0x424D_4541)); put(UInt32(1)); put(UInt32(dimension)); put(UInt32(entries.count))
        for (k, v) in entries where v.count == dimension {
            put(k)
            v.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// Builds the index: reuses cached vectors, embeds only what is new, in batches, reporting progress.
enum SemanticIndexBuilder {
    static func build(documents: [(path: String, text: String)], embedder: TextEmbedder, cacheDirectory: URL?, batch: Int = 64,
                      progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> SemanticIndex {
        let cache = cacheDirectory.map { EmbeddingCache(directory: $0, identity: embedder.identity) }
        var known = cache?.load()
        let keys = documents.map { EmbeddingCache.key(path: $0.path, text: $0.text) }
        var vectors = [[Float]?](repeating: nil, count: documents.count)
        var dim = known?.dimension ?? 0
        if let k = known { for (i, key) in keys.enumerated() { vectors[i] = k.vectors[key] } }
        known = nil                                                                   // free the cache copy before embedding
        let todo = vectors.indices.filter { vectors[$0] == nil }
        var done = documents.count - todo.count
        progress(done, documents.count)
        var start = 0
        while start < todo.count {
            try Task.checkCancellation()
            let slice = Array(todo[start..<min(todo.count, start + batch)])
            let out = try await embedder.embed(slice.map { documents[$0].text })
            guard out.count == slice.count else { throw SemanticSearchError.inconsistent }
            for (j, i) in slice.enumerated() {
                if dim == 0 { dim = out[j].count }
                guard out[j].count == dim else { throw SemanticSearchError.inconsistent }
                vectors[i] = out[j]
            }
            start += slice.count; done += slice.count
            progress(done, documents.count)
        }
        if documents.isEmpty { return SemanticIndex(dimension: 1, paths: [], normalized: []) }
        // a cache from a model with another vector size is useless: keep only vectors of the current size
        var flat = [Float](); flat.reserveCapacity(documents.count * dim)
        var cacheEntries: [(UInt64, [Float])] = []
        cacheEntries.reserveCapacity(documents.count)
        for (i, v) in vectors.enumerated() {
            let raw = (v?.count == dim ? v : nil) ?? [Float](repeating: 0, count: dim)
            cacheEntries.append((keys[i], raw))
            flat += SemanticIndex.normalized(raw)
        }
        cache?.save(dimension: dim, entries: cacheEntries)
        return SemanticIndex(dimension: dim, paths: documents.map(\.path), normalized: flat)
    }
}

/// The app's semantic search: owns the index while the feature is allowed, answers queries from the Search page.
@MainActor
final class SemanticSearchService: ObservableObject {
    enum State: Equatable {
        case idle
        case indexing(done: Int, total: Int)
        case ready(songs: Int)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastQuery = ""
    @Published private(set) var results: [TrackDTO] = []

    /// Hands over a reader of the songs to index; the reader runs on a background thread.
    var library: () -> (@Sendable () -> [TrackDTO]) = { { [] } }
    var analysis: @Sendable (String) -> DJTrackAnalysis? = { AnalysisCache.shared.cached(path: $0) }
    var makeEmbedder: () throws -> TextEmbedder = { OnDeviceEmbedder() }
    var isAllowed: () -> Bool = { IntelligenceGate.shared.isEnabled(.semanticSearch) }
    var cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Aureon/Semantic", isDirectory: true)
    var limit = 24

    private var index: SemanticIndex?
    private var tracksByPath: [String: TrackDTO] = [:]
    private var embedder: TextEmbedder?
    private var building: Task<SemanticIndex?, Never>?
    private var epoch = 0

    var isLoaded: Bool { index != nil }
    var indexBytes: Int { index?.bytes ?? 0 }

    /// Songs that match `query` by meaning. Builds the index first if it is not there. Returns [] when the feature is not allowed.
    @discardableResult
    func search(_ query: String) async -> [TrackDTO] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAllowed(), !q.isEmpty else { results = []; lastQuery = q; return [] }
        lastQuery = q
        let my = epoch
        guard let idx = await ensureIndex(), epoch == my, let embedder else { if epoch == my { results = [] }; return [] }
        do {
            let v = try await embedder.embed([q]).first ?? []
            let lim = limit
            let hits = await Task.detached(priority: .userInitiated) { idx.search(v, limit: lim) }.value
            guard epoch == my, lastQuery == q else { return results }
            results = hits.compactMap { tracksByPath[$0.path] }
            return results
        } catch {
            if epoch == my { state = .failed(error.localizedDescription); results = [] }
            return []
        }
    }

    /// Builds the index once; concurrent callers wait for the same build.
    func ensureIndex() async -> SemanticIndex? {
        if let index { return index }
        if let building { return await building.value }
        guard isAllowed() else { return nil }
        let e: TextEmbedder
        do { e = try makeEmbedder() } catch { state = .failed(error.localizedDescription); return nil }
        embedder = e
        let my = epoch, lib = library(), an = analysis, dir = cacheDirectory
        state = .indexing(done: 0, total: 0)
        let task = Task<SemanticIndex?, Never> { [weak self] in
            let built: Result<(SemanticIndex, [String: TrackDTO]), Error> = await Task.detached(priority: .utility) {
                let tracks = lib()
                let docs = tracks.map { (path: $0.path, text: SemanticDescriptor.text(for: $0, analysis: an($0.path))) }
                do {
                    let idx = try await SemanticIndexBuilder.build(documents: docs, embedder: e, cacheDirectory: dir) { done, total in
                        Task { @MainActor [weak self] in guard let self, self.epoch == my else { return }; self.state = .indexing(done: done, total: total) }
                    }
                    var map: [String: TrackDTO] = [:]
                    map.reserveCapacity(tracks.count)
                    for t in tracks { map[t.path] = t }
                    return .success((idx, map))
                } catch { return .failure(error) }
            }.value
            guard let self, self.epoch == my else { return nil }
            self.building = nil
            switch built {
            case .success(let (idx, map)):
                self.index = idx; self.tracksByPath = map; self.state = .ready(songs: idx.count)
                return idx
            case .failure(let err):
                self.state = .failed(err.localizedDescription)
                return nil
            }
        }
        building = task
        return await task.value
    }

    /// Frees the index and stops a build in progress (the master switch or the feature was turned off, or the model changed).
    func release() {
        epoch += 1
        building?.cancel(); building = nil
        index = nil; tracksByPath = [:]; embedder = nil
        results = []; state = .idle
    }

    /// The library changed: the next search rebuilds (cached vectors make that quick).
    func invalidate() {
        guard index != nil || building != nil else { return }
        release()
    }
}

extension SemanticSearchService {
    /// How close each song is in meaning to `query` (path → 0…1), for features that blend meaning into their own ranking.
    /// Returns nil while the index is not built yet (and starts building it, so the next request has it); [] when nothing is close.
    func similaritiesIfReady(to query: String, limit: Int = 3000) async -> [String: Float]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAllowed(), !q.isEmpty else { return nil }
        guard let idx = index, let embedder else {
            if building == nil { Task { _ = await ensureIndex() } }
            return nil
        }
        let my = epoch
        guard let v = try? await embedder.embed([q]).first, !v.isEmpty else { return nil }
        let hits = await Task.detached(priority: .userInitiated) { idx.search(v, limit: limit, minScore: 0.15, window: 0.5) }.value
        guard epoch == my else { return nil }
        return Dictionary(hits.map { ($0.path, max(0, $0.score)) }, uniquingKeysWith: max)
    }
}
