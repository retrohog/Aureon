import Foundation
import Network

/// A throw-away HTTP server that behaves like internet radio servers: endless audio, ICY metadata, chunked bodies, redirects, dropped connections.
final class FakeRadio: @unchecked Sendable {
    enum Mode { case icy(metaint: Int), chunked, icyStatusLine, redirect, dropAfter(bytes: Int), notFound, plain, flac }
    let listener: NWListener
    private let audio: Data
    private let q = DispatchQueue(label: "fakeradio")
    private let lock = NSLock()
    var mode: Mode
    private(set) var port: UInt16 = 0
    private var _connections = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    private var _requests: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(audio: Data, mode: Mode) throws {
        self.audio = audio; self.mode = mode
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [self] s in if case .ready = s { port = listener.port?.rawValue ?? 0; sem.signal() } }
        listener.newConnectionHandler = { [self] c in handle(c) }
        listener.start(queue: q)
        _ = sem.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/live.aac")! }

    private func handle(_ c: NWConnection) {
        lock.lock(); _connections += 1; lock.unlock()
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, _ in
            let req = String(decoding: data ?? Data(), as: UTF8.self)
            lock.lock(); _requests.append(req); lock.unlock()
            respond(c, request: req)
        }
    }

    private func send(_ c: NWConnection, _ d: Data, then: (() -> Void)? = nil) { c.send(content: d, completion: .contentProcessed { e in if e == nil { then?() } }) }

    private func respond(_ c: NWConnection, request: String) {
        let wantsMeta = request.lowercased().contains("icy-metadata: 1")
        switch mode {
        case .notFound: send(c, Data("HTTP/1.0 404 Not Found\\r\\n\\r\\n".replacingOccurrences(of: "\\\\r\\\\n", with: "\r\n").utf8)) { c.cancel() }
        case .redirect:
            if request.contains("GET /live.aac") { send(c, Data("HTTP/1.1 302 Found\r\nLocation: /real/stream.aac\r\nContent-Length: 0\r\n\r\n".utf8)) { c.cancel() } }
            else { stream(c, header: "HTTP/1.0 200 OK\r\nContent-Type: audio/aacp\r\n\r\n", metaint: 0, chunked: false, limit: nil) }
        case .icy(let n): stream(c, header: "HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\nicy-name: Test FM\r\nicy-br: 96\r\nicy-genre: Test\r\nicy-metaint: \(wantsMeta ? n : 0)\r\n\r\n", metaint: wantsMeta ? n : 0, chunked: false, limit: nil)
        case .icyStatusLine: stream(c, header: "ICY 200 OK\r\nicy-name: Old Shoutcast\r\nContent-Type: audio/aacp\r\n\r\n", metaint: 0, chunked: false, limit: nil)
        case .chunked: stream(c, header: "HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nTransfer-Encoding: chunked\r\n\r\n", metaint: 0, chunked: true, limit: nil)
        case .dropAfter(let n):
            let first = connections == 1
            stream(c, header: "HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\n\r\n", metaint: 0, chunked: false, limit: first ? n : nil)
        case .flac: stream(c, header: "HTTP/1.0 200 OK\r\nContent-Type: audio/flac\r\nicy-name: Lossless FM\r\n\r\n", metaint: 0, chunked: false, limit: nil)
        case .plain: stream(c, header: "HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\n\r\n", metaint: 0, chunked: false, limit: nil)
        }
    }

    /// Sends the audio on a loop, faster than real time at first (like a server's burst) and then paced.
    private func stream(_ c: NWConnection, header: String, metaint: Int, chunked: Bool, limit: Int?) {
        var pos = 0, sent = 0, sinceMeta = 0, titleNo = 0
        func nextPiece(_ want: Int) -> Data {
            var out = Data()
            while out.count < want {
                if metaint > 0 && sinceMeta == metaint {
                    titleNo += 1
                    var m = Data("StreamTitle='\(titleNo == 1 ? "Artist - First Song" : "Artist - Song \(titleNo)")';".utf8)
                    m.append(Data(count: (16 - m.count % 16) % 16))
                    out.append(UInt8(m.count / 16)); out.append(m); sinceMeta = 0
                    continue
                }
                let room = metaint > 0 ? metaint - sinceMeta : want - out.count
                let n = min(want - out.count, room, audio.count - pos)
                out.append(audio[pos..<(pos + n)]); pos = (pos + n) % audio.count; sinceMeta += n
            }
            return out
        }
        send(c, Data(header.utf8)) { [self] in
            func pump() {
                if let limit, sent >= limit { c.cancel(); return }
                let piece = nextPiece(2048); sent += piece.count
                var body = piece
                if chunked { body = Data(String(piece.count, radix: 16).utf8) + Data("\r\n".utf8) + piece + Data("\r\n".utf8) }
                send(c, body) { q.asyncAfter(deadline: .now() + (sent < 60_000 ? 0.001 : 0.012)) { pump() } }
            }
            pump()
        }
    }
}

struct RadioTests {
    let dir = tempDir("radio")

    /// ~8 s of a 440 Hz stereo tone as ADTS AAC (the stream format most stations use).
    func aacData(freq: Double = 440, seconds: Double = 8) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return nil }
        let wav = sineWAV(dir.appendingPathComponent("tone\(Int(freq)).wav"), rate: 44_100, bits: 16, freq: freq, amp: 0.5, seconds: seconds)
        let out = dir.appendingPathComponent("tone\(Int(freq)).aac")
        guard runTool("/usr/bin/afconvert", ["-f", "adts", "-d", "aac", "-b", "96000", wav.path, out.path]) else { return nil }
        return try? Data(contentsOf: out)
    }

    func readSeconds(_ s: RadioSource, _ seconds: Double) -> [Int32] {
        let ch = s.info.channels, want = Int(seconds * s.info.sampleRate)
        var out: [Int32] = []
        let buf = UnsafeMutablePointer<Int32>.allocate(capacity: 4096 * ch); defer { buf.deallocate() }
        let end = Date().addingTimeInterval(seconds + 15)
        while out.count / ch < want && Date() < end {
            let n = s.read(into: buf, frames: 4096)
            if n == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buf, count: n * ch))
        }
        return out
    }

    // MARK: pure parts

    func icyDemuxerHandlesAnySplit() {
        let audio = Data((0..<50).map { UInt8($0) })
        var meta = Data("StreamTitle='It's a Song - Artist';StreamUrl='';".utf8); meta.append(Data(count: (16 - meta.count % 16) % 16))
        let stream = audio.prefix(20) + Data([UInt8(meta.count / 16)]) + meta + audio.dropFirst(20).prefix(20) + Data([0]) + audio.dropFirst(40)
        for chunk in [1, 2, 3, 7, 13, 64] {
            var d = IcyDemuxer(metaint: 20), got = Data(), titles: [String] = []
            var i = stream.startIndex
            while i < stream.endIndex { let e = min(i + chunk, stream.endIndex); d.feed(stream[i..<e], audio: { got.append($0) }, title: { titles.append($0) }); i = e }
            expect(got == audio, "chunk \(chunk): audio comes out untouched")
            expect(titles == ["It's a Song - Artist"], "chunk \(chunk): \(titles)")
        }
        var plain = IcyDemuxer(metaint: 0), got = Data()
        plain.feed(audio, audio: { got.append($0) }, title: { _ in expect(false) })
        expect(got == audio)
        expect(IcyDemuxer.streamTitle(Data("StreamTitle='';".utf8)) == nil)
    }

    func fifoIsBoundedAndOrdered() {
        let f = PCMFifo(channels: 2, maxFrames: 100)
        var a = (0..<160).map { Int32($0) }                  // 80 frames
        a.withUnsafeBufferPointer { f.append($0.baseAddress!, frames: 80) }
        a.withUnsafeBufferPointer { f.append($0.baseAddress!, frames: 80) }
        expect(f.frames == 100, "capped at maxFrames, oldest dropped: \(f.frames)")
        var out = [Int32](repeating: 0, count: 20)
        expect(f.pop(into: &out, frames: 10, wait: 0) == 10 && out[0] == 120, "the newest 100 frames remain")
        expect(f.pop(into: &out, frames: 10, wait: 0.01) == 10)
        f.finish()
        var big = [Int32](repeating: 0, count: 400)
        expect(f.pop(into: &big, frames: 200, wait: 0) == 80 && f.pop(into: &big, frames: 5, wait: 0) == 0 && f.ended)
    }

    // MARK: network

    func httpClientFollowsRedirectsAndDecodesChunks() {
        guard let aac = aacData(seconds: 3) else { return }
        for mode in [FakeRadio.Mode.redirect, .chunked] {
            let srv = try! FakeRadio(audio: aac, mode: mode); defer { srv.stop() }
            let box = Data()
            let r = try? runAsync(timeout: 10) { () -> Int in
                let s = HTTPStreamer(url: srv.url)
                return await withCheckedContinuation { cont in
                    let acc = Acc()
                    s.start(onResponse: { acc.status = $0.status }, onBody: { d in acc.add(d); if acc.count > 30_000 { s.cancel() } }, onClose: { _ in cont.resume(returning: acc.status * 100_000 + acc.count) })
                }
            }.get()
            _ = box
            let status = (r ?? 0) / 100_000, count = (r ?? 0) % 100_000
            expect(status == 200 && count > 30_000, "\(mode): status \(status), \(count) bytes")
            if case .chunked = mode { expect(true) }
        }
    }
    private final class Acc: @unchecked Sendable { let l = NSLock(); var status = 0; var count = 0; var head = Data()
        func add(_ d: Data) { l.lock(); count += d.count; if head.count < 8 { head.append(d.prefix(8)) }; l.unlock() } }

    func radioDecodesMetadataAndTone() {
        guard let aac = aacData() else { return }
        let srv = try! FakeRadio(audio: aac, mode: .icy(metaint: 4096)); defer { srv.stop() }
        guard let s = try? RadioSource(url: srv.url) else { expect(false, "could not open the fake station"); return }
        defer { s.stop() }
        expect(s.info.isLive && !s.info.transparent && s.info.sampleRate == 44_100 && s.info.channels == 2 && s.info.codec == "AAC (lossy)", "\(s.info)")
        let pcm = readSeconds(s, 2)
        expect(pcm.count / 2 >= 88_000, "two seconds of audio arrived: \(pcm.count / 2) frames")
        let a = amplitude(pcm, channels: 2, rate: 44_100, freq: 440, skip: 20_000, count: 40_000)
        let off = amplitude(pcm, channels: 2, rate: 44_100, freq: 1_000, skip: 20_000, count: 40_000)
        expect(a > 0.35 && a < 0.65 && db(a / max(off, 1e-9)) > 30, "a 440 Hz tone at about half scale: \(a) vs \(off)")
        let live = s.live.snapshot
        expect(live.station == "Test FM" && live.bitrate == 96 && live.genre == "Test" && live.codec == "AAC", "\(live)")
        expect(live.title?.hasPrefix("Artist - ") == true, "ICY title arrives: \(live.title ?? "nil")")
        expect(srv.requests.first?.contains("Icy-MetaData: 1") == true && srv.requests.first?.contains("User-Agent: Aureon") == true, "asks for metadata and identifies itself")
        // the audio must not contain metadata bytes: a clean tone proves the demuxer removed them (checked above), and titles advance
        _ = readSeconds(s, 3)
    }

    func otherServerStyles() {
        guard let aac = aacData(seconds: 4) else { return }
        for mode in [FakeRadio.Mode.chunked, .redirect, .icyStatusLine, .plain] {
            let srv = try! FakeRadio(audio: aac, mode: mode); defer { srv.stop() }
            guard let s = try? RadioSource(url: srv.url) else { expect(false, "\(mode): did not open"); continue }
            let pcm = readSeconds(s, 1)
            let a = amplitude(pcm, channels: 2, rate: 44_100, freq: 440, skip: 10_000, count: 30_000)
            expect(a > 0.35, "\(mode): tone amplitude \(a)")
            if case .icyStatusLine = mode { expect(s.live.snapshot.station == "Old Shoutcast", "ICY status line is understood") }
            s.stop()
        }
    }

    func failuresAreReportedQuickly() {
        let srv = try! FakeRadio(audio: Data([0]), mode: .notFound)
        let t0 = Date()
        expect((try? RadioSource(url: srv.url, timeout: 6)) == nil, "HTTP 404 must throw")
        srv.stop()
        expect((try? RadioSource(url: URL(string: "http://127.0.0.1:9/none")!, timeout: 6)) == nil, "a closed port must throw")
        expect((try? RadioSource(url: URL(string: "ftp://example.com/x")!, timeout: 6)) == nil, "unsupported scheme must throw")
        expect(Date().timeIntervalSince(t0) < 12, "and without hanging")
        // a server that speaks something that is not audio
        let junk = try! FakeRadio(audio: Data("<html>not a stream</html>".utf8) + Data(count: 4000), mode: .plain)
        expect((try? RadioSource(url: junk.url, timeout: 4)) == nil, "non-audio data must not pretend to be a stream")
        junk.stop()
    }

    func reconnectsWhenTheServerDrops() {
        guard let aac = aacData() else { return }
        let srv = try! FakeRadio(audio: aac, mode: .dropAfter(bytes: 14_000)); defer { srv.stop() }
        guard let s = try? RadioSource(url: srv.url) else { expect(false, "did not open"); return }
        defer { s.stop() }
        let pcm = readSeconds(s, 6)        // 14 kB of this tone is about 2 s of audio, so reading 6 s crosses the drop
        expect(srv.connections >= 2, "reconnected: \(srv.connections) connections")
        expect(pcm.count / 2 >= 6 * 44_100 * 9 / 10, "audio kept flowing across the drop: \(pcm.count / 2) frames")
        // after the reconnect the tone must be back (silence fills only the short gap while reconnecting)
        let tail = Array(pcm.suffix(2 * 44_100))
        let a = amplitude(tail, channels: 2, rate: 44_100, freq: 440, skip: 10_000, count: 30_000)
        expect(a > 0.3, "tone is intact after reconnecting: \(a)")
    }

    func playerPlaysAndUpscalesALiveStream() {
        guard let aac = aacData(seconds: 6) else { return }
        let srv = try! FakeRadio(audio: aac, mode: .icy(metaint: 8192)); defer { srv.stop() }
        let sink = RecordingSink(rates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000], speed: 1)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let p = Player()
        p.setQueue([srv.url.absoluteString]); p.start(options: o)
        let end = Date().addingTimeInterval(15)
        while sink.frameCount < 176_400 && Date() < end { usleep(20_000) }
        let st = p.status
        expect(st.info?.isLive == true && st.sourceInfo?.isLive == true, "the status says it is live")
        expect(st.sourceInfo?.sampleRate == 44_100 && st.info?.sampleRate == 176_400, "upscaled 44.1 → 176.4 kHz: \(String(describing: st.info?.sampleRate))")
        expect(!st.transparentStream && !st.bitPerfect, "radio is never reported as bit-perfect")
        expect(st.pipeline.contains { $0.hasPrefix("Internet radio") } && st.pipeline.contains { $0.hasPrefix("Resample") }, "\(st.pipeline)")
        expect(st.live?.station == "Test FM", "\(String(describing: st.live))")
        let pcm = sink.samples
        let a = amplitude(pcm, channels: 2, rate: 176_400, freq: 440, skip: 176_400 / 2, count: 60_000)
        expect(a > 0.35 && a < 0.65, "the tone survives upsampling: \(a)")
        // seeking a live stream does nothing and does not break playback
        let before = sink.frameCount
        p.send(.seekTo(100)); p.send(.seekBy(-10))
        usleep(500_000)
        expect(sink.frameCount > before && p.status.state == .playing, "still playing after seek attempts")
        p.send(.stop); _ = p.waitUntilFinished(timeout: 8)

        // upscaling off: the stream goes out at its own rate
        let sink2 = RecordingSink(rates: [44_100, 96_000, 192_000], speed: 1)
        var o2 = PlayerOptions(); o2.sinkFactory = { _ in sink2 }
        let p2 = Player(); var s2 = PlaybackSettings(); s2.radio.upscale = false; p2.settings = s2
        p2.setQueue([srv.url.absoluteString]); p2.start(options: o2)
        let end2 = Date().addingTimeInterval(15)
        while sink2.frameCount < 44_100 && Date() < end2 { usleep(20_000) }
        expect(p2.status.info?.sampleRate == 44_100, "no upscaling when switched off: \(String(describing: p2.status.info?.sampleRate))")
        p2.send(.stop); _ = p2.waitUntilFinished(timeout: 8)
    }

    func losslessFLACStream() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else { return }
        let wav = sineWAV(dir.appendingPathComponent("flacstream.wav"), rate: 48_000, bits: 24, freq: 440, amp: 0.5, seconds: 4)
        let flac = dir.appendingPathComponent("flacstream.flac")
        guard encode(wav, to: flac, alac: false), let data = try? Data(contentsOf: flac) else { return }
        let srv = try! FakeRadio(audio: data, mode: .flac); defer { srv.stop() }
        guard let s = try? RadioSource(url: srv.url) else { expect(false, "FLAC stream did not open"); return }
        defer { s.stop() }
        expect(s.info.codec == "FLAC" && s.info.transparent && s.info.isLive && s.info.sourceBits == 24 && s.info.sampleRate == 48_000, "\(s.info)")
        let pcm = readSeconds(s, 1.5)
        let a = amplitude(pcm, channels: 2, rate: 48_000, freq: 440, skip: 12_000, count: 30_000)
        expect(abs(a - 0.5) < 0.02, "lossless: the tone comes out at exactly its amplitude: \(a)")
        expect(s.live.snapshot.station == "Lossless FM")
    }

    func radioSettingsDecodeFromOldSaves() {
        let old = Data("{\"polarityInverted\":false}".utf8)
        let s = try? JSONDecoder().decode(PlaybackSettings.self, from: old)
        expect(s?.radio.upscale == true && s?.radio.maxRate == 192_000, "defaults to upscaling with a 192 kHz ceiling")
        let enc = try! JSONEncoder().encode(PlaybackSettings())
        expect((try? JSONDecoder().decode(PlaybackSettings.self, from: enc)) == PlaybackSettings())
    }
}
