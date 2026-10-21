import Foundation
import AudioToolbox

/// What a live stream tells us about itself: station name, bit rate and the current "artist - title" (ICY metadata).
final class LiveMetadata: @unchecked Sendable {
    struct Snapshot: Equatable { var station: String?; var title: String?; var bitrate: Int?; var codec: String?; var genre: String? }
    private let lock = NSLock()
    private var s = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }
    func update(_ f: (inout Snapshot) -> Void) { lock.lock(); f(&s); lock.unlock() }
}

/// Separates SHOUTcast/Icecast metadata blocks from the audio bytes. With `icy-metaint: N` the server inserts a length byte (×16) and that
/// many bytes of "StreamTitle='…';" after every N audio bytes.
struct IcyDemuxer {
    private(set) var metaint: Int
    private var untilMeta: Int
    private var metaLeft = 0
    private var meta = Data()
    private var needLength = false

    init(metaint: Int) { self.metaint = max(0, metaint); untilMeta = max(0, metaint) }

    mutating func feed(_ data: Data, audio: (Data) -> Void, title: (String) -> Void) {
        guard metaint > 0 else { audio(data); return }
        var i = data.startIndex
        while i < data.endIndex {
            if needLength {
                metaLeft = Int(data[i]) * 16; i += 1; needLength = false; meta = Data()
                if metaLeft == 0 { untilMeta = metaint }
                continue
            }
            if metaLeft > 0 {
                let n = min(metaLeft, data.endIndex - i)
                meta.append(data[i..<(i + n)]); i += n; metaLeft -= n
                if metaLeft == 0 { if let t = Self.streamTitle(meta) { title(t) }; untilMeta = metaint }
                continue
            }
            let n = min(untilMeta, data.endIndex - i)
            audio(data[i..<(i + n)]); i += n; untilMeta -= n
            if untilMeta == 0 { needLength = true }
        }
    }

    static func streamTitle(_ d: Data) -> String? {
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        guard let r = s.range(of: "StreamTitle='") else { return nil }
        let rest = s[r.upperBound...]
        // the value ends at "';" (a title may itself contain apostrophes)
        let end = rest.range(of: "';") ?? rest.range(of: "'", options: .backwards)
        let t = String(rest[..<(end?.lowerBound ?? rest.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : t
    }
}

/// Decoded PCM waiting to be pulled by the player: bounded, thread-safe.
final class PCMFifo: @unchecked Sendable {
    private let cond = NSCondition()
    private var data: [Int32] = []
    private var head = 0
    private(set) var ended = false
    let channels: Int
    let maxFrames: Int

    init(channels: Int, maxFrames: Int) { self.channels = channels; self.maxFrames = maxFrames }

    var frames: Int { cond.lock(); defer { cond.unlock() }; return (data.count - head) / channels }

    func append(_ p: UnsafePointer<Int32>, frames n: Int) {
        cond.lock()
        data.append(contentsOf: UnsafeBufferPointer(start: p, count: n * channels))
        let over = (data.count - head) / channels - maxFrames
        if over > 0 { head += over * channels }                    // a stalled consumer must not grow memory without limit
        if head > 1 << 20 && head > data.count / 2 { data.removeSubrange(0..<head); head = 0 }
        cond.broadcast(); cond.unlock()
    }

    func finish() { cond.lock(); ended = true; cond.broadcast(); cond.unlock() }

    /// Up to `frames` frames. Waits at most `wait` seconds for data; returns what is there (possibly 0).
    func pop(into out: UnsafeMutablePointer<Int32>, frames n: Int, wait: TimeInterval) -> Int {
        cond.lock(); defer { cond.unlock() }
        if (data.count - head) == 0, !ended { _ = cond.wait(until: Date().addingTimeInterval(wait)) }
        let avail = (data.count - head) / channels
        let take = min(n, avail)
        if take > 0 {
            data.withUnsafeBufferPointer { src in out.update(from: src.baseAddress! + head, count: take * channels) }
            head += take * channels
            if head == data.count { data.removeAll(keepingCapacity: true); head = 0 }
        }
        return take
    }

    func waitUntil(frames n: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while (data.count - head) / channels < n && !ended {
            if !cond.wait(until: deadline) { break }
        }
        return (data.count - head) / channels >= n
    }
}

/// A live internet-radio stream as a `FrameSource`: network bytes → ICY demux → AudioFileStream (MP3 / AAC-ADTS) → AudioConverter → 32-bit integer PCM.
///
/// `read` never blocks the player's decode thread for long: when the network is slow it returns a short block of silence so commands
/// (pause, stop, skip) stay responsive. The source reconnects by itself if the server drops the connection.
final class RadioSource: FrameSource, @unchecked Sendable {
    private(set) var info: StreamInfo
    let live = LiveMetadata()
    private let url: URL
    private var fifo: PCMFifo
    private var streamer: HTTPStreamer?
    private var icy = IcyDemuxer(metaint: 0)
    private var parser: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var srcFormat = AudioStreamBasicDescription()
    private var outChannels = 2
    private var codecName = "Radio"
    private var stopped = false
    private var reconnects = 0
    private var discontinuity = false
    private let ready = DispatchSemaphore(value: 0)
    private var readySignalled = false
    private var failure: Error?
    private let lock = NSLock()
    private let q = DispatchQueue(label: "aureon.radio.decode")
    private static let queueKey = DispatchSpecificKey<Void>()

    /// Connects and waits until the stream's format is known and about half a second is buffered.
    init(url: URL, timeout: TimeInterval = 12) throws {
        self.url = url
        q.setSpecific(key: Self.queueKey, value: ())
        fifo = PCMFifo(channels: 2, maxFrames: 1)
        info = StreamInfo(sampleRate: 44_100, channels: 2, sourceBits: 16, totalFrames: 0, codec: "Radio (lossy)", transparent: false)
        connect()
        if ready.wait(timeout: .now() + timeout) == .timedOut { stop(); throw AureonError.message("the station did not answer") }
        if let f = failure { stop(); throw f }
        guard parser != nil, converter != nil else { stop(); throw AureonError.message("unsupported stream format") }
        _ = fifo.waitUntil(frames: Int(info.sampleRate / 2), timeout: 4)
    }

    deinit { stop() }

    func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        if already { return }
        streamer?.cancel(); streamer = nil
        // the parser and converter are only ever used on `q`: close them there, so a packet in flight cannot meet a closed stream
        let teardown = {
            if let p = self.parser { AudioFileStreamClose(p); self.parser = nil }
            if let c = self.converter { AudioConverterDispose(c); self.converter = nil }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { teardown() } else { q.sync(execute: teardown) }
        fifo.finish()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func signalReady() { if !readySignalled { readySignalled = true; ready.signal() } }

    // MARK: network

    private func connect() {
        let s = HTTPStreamer(url: url, headers: ["Icy-MetaData": "1"])
        streamer = s
        s.start(onResponse: { [weak self] r in self?.q.async { self?.onResponse(r) } },
                onBody: { [weak self] d in self?.q.async { self?.onBytes(d) } },
                onClose: { [weak self] e in self?.q.async { self?.onClose(e) } })
    }

    private func onResponse(_ r: HTTPStreamer.Response) {
        guard (200..<300).contains(r.status) else { failure = AureonError.message("HTTP \(r.status)"); signalReady(); return }
        icy = IcyDemuxer(metaint: Int(r.headers["icy-metaint"] ?? "") ?? 0)
        live.update { $0.station = r.headers["icy-name"] ?? $0.station; $0.bitrate = Int(r.headers["icy-br"] ?? "") ?? $0.bitrate; $0.genre = r.headers["icy-genre"] ?? $0.genre }
        if parser == nil {
            var hint: AudioFileTypeID = 0
            let ct = (r.headers["content-type"] ?? "").lowercased()
            if ct.contains("mpeg") || ct.contains("mp3") { hint = kAudioFileMP3Type } else if ct.contains("aac") { hint = kAudioFileAAC_ADTSType } else if ct.contains("flac") { hint = kAudioFileFLACType }
            var id: AudioFileStreamID?
            let me = Unmanaged.passUnretained(self).toOpaque()
            let st = AudioFileStreamOpen(me, { c, stream, pid, _ in
                Unmanaged<RadioSource>.fromOpaque(c).takeUnretainedValue().property(stream, pid)
            }, { c, bytes, packets, data, descs in
                Unmanaged<RadioSource>.fromOpaque(c).takeUnretainedValue().packets(bytes, packets, data, descs)
            }, hint, &id)
            if st != noErr { failure = AureonError.message("cannot parse this stream (\(fourCC(UInt32(bitPattern: st))))"); signalReady() } else { parser = id }
        } else { discontinuity = true }
    }

    private func onBytes(_ d: Data) {
        guard !isStopped, let p = parser else { return }
        var audio = Data()
        icy.feed(d, audio: { audio.append($0) }, title: { [weak self] t in self?.live.update { $0.title = t } })
        guard !audio.isEmpty else { return }
        let flags: AudioFileStreamParseFlags = discontinuity ? .discontinuity : []
        discontinuity = false
        audio.withUnsafeBytes { raw in _ = AudioFileStreamParseBytes(p, UInt32(audio.count), raw.baseAddress, flags) }
    }

    private func onClose(_ e: Error?) {
        if isStopped { return }
        if converter == nil { failure = e ?? AureonError.message("the station closed the connection"); signalReady(); return }
        // a radio stream should never end: try again a few times, then give up and let the player move on
        reconnects += 1
        if reconnects > 6 { fifo.finish(); return }
        q.asyncAfter(deadline: .now() + 1) { [weak self] in if let self, !self.isStopped { self.connect() } }
    }

    // MARK: decoding

    private func property(_ id: AudioFileStreamID, _ prop: AudioFileStreamPropertyID) {
        guard prop == kAudioFileStreamProperty_ReadyToProducePackets, converter == nil else { return }
        var fmt = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: fmt))
        guard AudioFileStreamGetProperty(id, kAudioFileStreamProperty_DataFormat, &size, &fmt) == noErr else { return }
        // HE-AAC: the stream header gives the core rate; the format list names the real output rate (SBR)
        var listSize: UInt32 = 0, writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(id, kAudioFileStreamProperty_FormatList, &listSize, &writable) == noErr, listSize >= UInt32(MemoryLayout<AudioFormatListItem>.size) {
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(listSize) / MemoryLayout<AudioFormatListItem>.size)
            if AudioFileStreamGetProperty(id, kAudioFileStreamProperty_FormatList, &listSize, &items) == noErr, let best = items.max(by: { $0.mASBD.mSampleRate < $1.mASBD.mSampleRate }) { fmt = best.mASBD }
        }
        srcFormat = fmt
        let ch = Int(max(1, min(fmt.mChannelsPerFrame, 2)))
        var out = AudioStreamBasicDescription(mSampleRate: fmt.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch), mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&fmt, &out, &conv) == noErr, let conv else { failure = AureonError.message("no decoder for this stream"); signalReady(); return }
        // some codecs (FLAC) keep essential parameters in a "magic cookie" that the stream parser extracts from the header
        var cookieSize: UInt32 = 0, cookieWritable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookieWritable) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(id, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr { AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, cookieSize, cookie) }
        }
        converter = conv; outChannels = ch
        let lossless = fmt.mFormatID == kAudioFormatFLAC
        codecName = lossless ? "FLAC" : fmt.mFormatID == kAudioFormatMPEGLayer3 ? "MP3" : fmt.mFormatID == kAudioFormatMPEG4AAC_HE || fmt.mFormatID == kAudioFormatMPEG4AAC_HE_V2 ? "HE-AAC" : "AAC"
        let bits = lossless ? ([1: 16, 2: 20, 3: 24, 4: 32][Int(fmt.mFormatFlags)] ?? 16) : 16
        fifo = PCMFifo(channels: ch, maxFrames: Int(fmt.mSampleRate) * 45)
        info = StreamInfo(sampleRate: fmt.mSampleRate, channels: ch, sourceBits: bits, totalFrames: Int64(fmt.mSampleRate) * 86_400 * 30, codec: lossless ? codecName : codecName + " (lossy)", transparent: lossless, isLive: true)
        live.update { $0.codec = codecName }
        signalReady()
    }

    private final class Input { var base: UnsafeRawPointer; var descs: UnsafePointer<AudioStreamPacketDescription>?; var count: Int; var next = 0; var current = AudioStreamPacketDescription(); var bytesPerPacket: UInt32
        init(base: UnsafeRawPointer, descs: UnsafePointer<AudioStreamPacketDescription>?, count: Int, bpp: UInt32) { self.base = base; self.descs = descs; self.count = count; bytesPerPacket = bpp } }

    private static let noMoreData: OSStatus = 0x6e6f6d72     // 'nomr'

    private func packets(_ bytes: UInt32, _ count: UInt32, _ data: UnsafeRawPointer, _ descs: UnsafePointer<AudioStreamPacketDescription>?) {
        guard let conv = converter, !isStopped else { return }
        let input = Input(base: data, descs: descs, count: Int(count), bpp: srcFormat.mBytesPerPacket)
        let ptr = Unmanaged.passUnretained(input).toOpaque()
        let chunk = 4096, bpf = 4 * outChannels
        var pcm = [Int32](repeating: 0, count: chunk * outChannels)
        while true {
            var n = UInt32(chunk)
            let st: OSStatus = pcm.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(outChannels), mDataByteSize: UInt32(chunk * bpf), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(conv, { _, ioN, ioData, outDescs, user in
                    let inp = Unmanaged<Input>.fromOpaque(user!).takeUnretainedValue()
                    if inp.next >= inp.count { ioN.pointee = 0; return RadioSource.noMoreData }
                    var off = 0, size = Int(inp.bytesPerPacket)
                    if let d = inp.descs { off = Int(d[inp.next].mStartOffset); size = Int(d[inp.next].mDataByteSize) }
                    else { off = inp.next * size }
                    inp.current = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: inp.base + off)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(size)
                    ioN.pointee = 1
                    if let outDescs { withUnsafeMutablePointer(to: &inp.current) { outDescs.pointee = $0 } }
                    inp.next += 1
                    return noErr
                }, ptr, &n, &abl, nil)
            }
            if n > 0 { pcm.withUnsafeBufferPointer { fifo.append($0.baseAddress!, frames: Int(n)) } }
            if st != noErr || n == 0 { break }
        }
        if !readySignalled { signalReady() }
    }

    // MARK: FrameSource

    func seek(to frame: Int64) {}      // live: nothing to seek in

    func read(into buf: UnsafeMutablePointer<Int32>, frames: Int) -> Int {
        let n = fifo.pop(into: buf, frames: frames, wait: 0.03)
        if n > 0 { return n }
        if fifo.ended { return 0 }
        // network hiccup: a brief silence keeps the player responsive instead of blocking it
        let s = min(frames, 480)
        buf.update(repeating: 0, count: s * info.channels)
        return s
    }
}
