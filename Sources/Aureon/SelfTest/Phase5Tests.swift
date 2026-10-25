import Foundation
import AVFoundation
import Network
import Darwin

// MARK: - fakes

/// A UPnP/DLNA renderer (or Sonos player) in memory: records every SOAP call and plays "whole second" positions like real ones.
final class FakeRenderer: HTTPClient, @unchecked Sendable {
    let lock = NSLock()
    private(set) var calls: [(action: String, args: [String: String])] = []
    var failPlay = false
    var latency = 0.0                 // seconds between a frame being fed and being heard
    private var playStart: Date?
    var played: Bool { lock.lock(); defer { lock.unlock() }; return playStart != nil }

    func called(_ a: String) -> [[String: String]] { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.action == a }.map(\.args) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let action = (request.value(forHTTPHeaderField: "SOAPACTION") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "#").last.map(String.init) ?? ""
        var args: [String: String] = [:]
        if let body = request.httpBody, let root = XMLTree.parse(body), let a = root.find(action) { for c in a.children { args[c.name] = c.text } }
        lock.lock(); calls.append((action, args)); lock.unlock()
        func ok(_ inner: String = "") -> (Data, Int) {
            (Data("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>".utf8), 200)
        }
        switch action {
        case "Play":
            if failPlay { return (Data("<s:Envelope xmlns:s=\"x\"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8), 500) }
            lock.lock(); playStart = Date(); lock.unlock(); return ok()
        case "GetPositionInfo":
            lock.lock(); let start = playStart; lock.unlock()
            let t = start.map { max(0, Date().timeIntervalSince($0) - latency) } ?? 0
            let s = Int(t)
            return ok("<Track>1</Track><RelTime>\(s / 3600):\(String(format: "%02d", s / 60 % 60)):\(String(format: "%02d", s % 60))</RelTime>")
        default: return ok()
        }
    }
}

/// An LMS in memory: JSON-RPC library plus /music/<id>/download.
final class FakeLMS: HTTPClient, @unchecked Sendable {
    struct Track { var id: Int; var title: String; var artist: String; var album: String; var track: Int; var year: Int; var data: Data }
    let user = "squeeze", password = "box"
    var tracks: [Track] = []
    var supportsRange = true
    private let lock = NSLock()
    private(set) var log: [String] = []
    var requireAuth = true

    private func authorised(_ r: URLRequest) -> Bool {
        !requireAuth || r.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private func entry(_ t: Track) -> [String: Any] {
        // LMS sends many numbers as strings
        ["id": t.id, "title": t.title, "artist": t.artist, "album": t.album, "genre": "Jazz", "tracknum": "\(t.track)", "disc": "1", "year": "\(t.year)", "duration": 12.0,
         "filesize": "\(t.data.count)", "type": "flc", "samplerate": "44100", "samplesize": "16", "channels": "2", "coverid": "cov\(t.id)"]
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else { return (Data(), 400) }
        lock.lock(); log.append(url.path); lock.unlock()
        guard authorised(request) else { return (Data(), 401) }
        if url.path == "/jsonrpc.js" {
            guard let body = request.httpBody, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let params = j["params"] as? [Any], params.count == 2, let cmd = params[1] as? [Any], let name = cmd.first as? String else { return (Data(), 400) }
            var result: [String: Any] = [:]
            switch name {
            case "serverstatus": result = ["version": "9.0.0", "info total songs": tracks.count, "lastscan": "1700000000"]
            case "songs":
                let strs = cmd.compactMap { $0 as? String }
                if let tid = strs.first(where: { $0.hasPrefix("track_id:") }) {
                    let id = Int(tid.dropFirst(9))
                    let m = tracks.filter { $0.id == id }
                    result = ["count": m.count, "titles_loop": m.map(entry)]
                } else {
                    let start = (cmd[1] as? Int) ?? 0, count = (cmd[2] as? Int) ?? 0
                    result = ["count": tracks.count, "titles_loop": Array(tracks.dropFirst(start).prefix(count)).map(entry)]
                }
            default: break
            }
            return (try! JSONSerialization.data(withJSONObject: ["id": 1, "result": result]), 200)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "music", let id = Int(parts[1].replacingOccurrences(of: "cov", with: "")), let t = tracks.first(where: { $0.id == id }) else { return (Data(), 404) }
        if parts[2] == "download" {
            if let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes="), supportsRange {
                let n = r.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard n.count == 2, n[0] < t.data.count else { return (Data(), 416) }
                return (t.data.subdata(in: n[0]..<min(n[1] + 1, t.data.count)), 206)
            }
            return (t.data, 200)
        }
        return parts[2].hasPrefix("cover") ? (Data([0xFF, 0xD8, 0xFF, 1, 2]), 200) : (Data(), 404)
    }
}

/// A UDP responder on loopback for SSDP / LMS discovery tests.
final class UDPResponder: @unchecked Sendable {
    let port: UInt16
    private var running = true
    init(reply: @escaping @Sendable ([UInt8]) -> [UInt8]?) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        _ = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: a.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            while self?.running == true {
                var from = sockaddr_in(); var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fl) } }
                guard n > 0, let r = reply(Array(buf[0..<n])) else { continue }
                _ = withUnsafePointer(to: &from) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, r, r.count, 0, $0, fl) } }
            }
            close(fd)
        }.start()
    }
    func stop() { running = false }
}

// MARK: - tests

struct Phase5Tests {
    let dir = tempDir("phase5")

    // MARK: dither

    private func errors(_ mode: DitherMode, bits: Int = 16, n: Int = 1 << 18, seed: UInt64 = 7) -> (err: [Double], out: [Int32], inp: [Int32]) {
        var x = seed, inp = [Int32](repeating: 0, count: n)
        for i in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; inp[i] = Int32(truncatingIfNeeded: Int64(x >> 33) % (1 << 30) - (1 << 29)) & ~0xFF }       // 24-bit audio
        var out = inp
        let st = DitherStage(settings: DitherSettings(mode: mode, bits: bits), channels: 1)
        out.withUnsafeMutableBufferPointer { b in var p = 0; while p < n { let k = min(1000, n - p); st.process(b.baseAddress! + p, frames: k); p += k } }
        return (zip(out, inp).map { Double($0) - Double($1) }, out, inp)
    }
    private func variance(_ x: [Double]) -> Double { let m = x.reduce(0, +) / Double(x.count); return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count) }
    private func blockMeans(_ x: [Double], _ k: Int) -> [Double] { stride(from: 0, to: x.count - k, by: k).map { i in x[i..<(i + k)].reduce(0, +) / Double(k) } }

    func ditherStatistics() {
        let step = 65_536.0
        let off = errors(.off)
        expect(off.out == off.inp, "off leaves every sample alone")
        for bits in [16, 20, 24] {
            let s = Double(1 << (32 - bits))
            for mode in [DitherMode.tpdf, .highPassTPDF, .noiseShaped] {
                let r = errors(mode, bits: bits)
                expect(r.out.allSatisfy { Int64($0) % Int64(s) == 0 }, "\(mode) \(bits)-bit: every output is a multiple of one LSB")
                expect(abs(r.err.reduce(0, +) / Double(r.err.count)) < 0.02 * s, "\(mode) \(bits)-bit: no DC offset")
            }
        }
        // TPDF: quantisation error (1/12) plus two uniform dithers (2/12) = 1/4 LSB², whatever the signal
        let t = errors(.tpdf)
        expect(abs(variance(t.err) / (step * step) - 0.25) < 0.01, "TPDF error power is 1/4 LSB²: \(variance(t.err) / (step * step))")
        // noise below 1/16 of the sample rate: shaping moves it away, high-pass TPDF removes most of the dither's share
        let low = blockMeans(t.err, 16).map { $0 * $0 }.reduce(0, +) / Double(t.err.count / 16)
        let hp = errors(.highPassTPDF), ns = errors(.noiseShaped)
        let lowHP = blockMeans(hp.err, 16).map { $0 * $0 }.reduce(0, +) / Double(hp.err.count / 16)
        let lowNS = blockMeans(ns.err, 64).map { $0 * $0 }.reduce(0, +) / Double(ns.err.count / 64), lowT64 = blockMeans(t.err, 64).map { $0 * $0 }.reduce(0, +) / Double(t.err.count / 64)
        expect(lowHP < low * 0.6, "high-pass TPDF has less low-frequency noise: \(lowHP) vs \(low)")
        expect(lowNS < lowT64 * 0.1, "noise shaping removes most of it: \(lowNS) vs \(lowT64)")
        expect(variance(ns.err) > variance(t.err) * 2, "…by putting it at the top of the spectrum, where there is more of it in total")
    }

    func ditherKeepsQuietSignals() {
        // a sine a quarter of one LSB high: without dither it rounds to silence; with it, the average output still follows the sine
        let n = 64 * 4096, amp = 16_384.0
        var inp = [Int32](repeating: 0, count: n)
        for i in 0..<n { inp[i] = Int32((amp * sin(2 * .pi * Double(i) / 64)).rounded()) }
        func projection(_ out: [Int32]) -> Double { 2 / Double(n) * (0..<n).reduce(0.0) { $0 + Double(out[$1]) * sin(2 * .pi * Double($1) / 64) } }
        let plain = inp.map { (v: Int32) -> Int32 in Int32(((Int64(v) + 32_768) >> 16) * 65_536) }
        expect(abs(projection(plain)) < 1, "undithered rounding loses the signal entirely: \(projection(plain))")
        for mode in [DitherMode.tpdf, .highPassTPDF, .noiseShaped] {
            var out = inp
            let st = DitherStage(settings: DitherSettings(mode: mode, bits: 16), channels: 1)
            out.withUnsafeMutableBufferPointer { st.process($0.baseAddress!, frames: n) }
            expect(abs(projection(out) - amp) < amp * 0.1, "\(mode): the signal survives below one LSB: \(projection(out)) of \(amp)")
        }
    }

    func ditherSafety() {
        for mode in [DitherMode.tpdf, .highPassTPDF, .noiseShaped] {
            var x = [Int32](repeating: .max, count: 5000) + [Int32](repeating: .min, count: 5000) + (0..<5000).map { $0 % 2 == 0 ? Int32.max : Int32.min }
            let st = DitherStage(settings: DitherSettings(mode: mode, bits: 16), channels: 2)
            x.withUnsafeMutableBufferPointer { st.process($0.baseAddress!, frames: 7500) }
            expect(x[0..<5000].allSatisfy { $0 > 2_000_000_000 } && x[5000..<10_000].allSatisfy { $0 < -2_000_000_000 }, "\(mode): full scale clips, it never wraps to the other sign")
            expect(x.allSatisfy { Int64($0) % 65_536 == 0 }, "\(mode): and stays on the 16-bit grid")
        }
        // channels are independent: a silent channel stays silent apart from its own dither, and two channels do not share noise
        var st = [Int32](repeating: 0, count: 20_000)
        let d = DitherStage(settings: DitherSettings(mode: .tpdf, bits: 16), channels: 2)
        st.withUnsafeMutableBufferPointer { d.process($0.baseAddress!, frames: 10_000) }
        let l = stride(from: 0, to: 20_000, by: 2).map { st[$0] }, r = stride(from: 1, to: 20_000, by: 2).map { st[$0] }
        expect(l != r, "the two channels get different dither")
        expect(l.allSatisfy { abs(Int64($0)) <= 65_536 } , "TPDF dither on silence is at most ±1 LSB")
    }

    func ditherInThePlayer() {
        let wav = writeWAV(dir.appendingPathComponent("dither.wav"), rate: 44_100, bits: 24, frames: 30_000) { f, c in c == 0 ? ((f * 37) % 1_000_000 - 500_000) : (f % 3 - 1) }
        let want = readAll(try! LosslessFile(path: wav.path))
        func run(_ d: DitherSettings) -> [Int32] {
            let sink = RecordingSink()
            var o = PlayerOptions(); o.sinkFactory = { _ in sink }
            let p = Player()
            var s = PlaybackSettings(); s.rt.dither = d; p.settings = s
            p.setQueue([wav.path]); p.start(options: o)
            expect(p.waitUntilFinished(timeout: 15))
            return sink.samples
        }
        expect(run(DitherSettings(mode: .off)) == want, "with dither off the stream is bit-exact")
        let got = run(DitherSettings(mode: .tpdf, bits: 16))
        expect(got.count == want.count && got.allSatisfy { $0 % 65_536 == 0 }, "through the player the stream is on the 16-bit grid")
        expect(zip(got, want).allSatisfy { abs(Int64($0) - Int64($1)) <= 98_304 }, "and within 1.5 LSB of the source")
        let json = try! JSONEncoder().encode(RTSettings())
        var old = try! JSONSerialization.jsonObject(with: json) as! [String: Any]; old["dither"] = nil
        expect((try? JSONDecoder().decode(RTSettings.self, from: JSONSerialization.data(withJSONObject: old))) != nil, "settings saved before dither existed still load")
    }

    // MARK: zone

    func delayLineIsSampleExact() {
        let ch = 2
        func ramp(_ from: Int, _ n: Int) -> [Int32] { (from..<(from + n)).flatMap { [Int32($0), Int32(-$0)] } }
        var d = SampleDelay(channels: ch, maxDelayFrames: 5000, maxBlockFrames: 1024)
        var outAll: [Int32] = []
        func feed(_ from: Int, _ n: Int) { let inp = ramp(from, n); var out = [Int32](repeating: 9, count: n * ch); inp.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { d.process(i.baseAddress!, frames: n, output: $0.baseAddress!) } }; outAll += out }
        d.target = 300
        feed(0, 1000); feed(1000, 700)
        // 300 frames of silence, then the input from its start
        expect(Array(outAll[0..<600]) == [Int32](repeating: 0, count: 600) && Array(outAll[600..<(600 + 2 * 1400)]) == ramp(0, 1400), "a delay of 300 frames: silence, then the input unchanged")
        // more delay: silence is inserted at once, nothing is lost
        d.target = 800
        feed(1700, 1000)
        let tail = Array(outAll[(2 * 1700)...])
        expect(Array(tail[0..<(2 * 300)]) == ramp(1400, 300) && Array(tail[(2 * 300)..<(2 * 800)]) == [Int32](repeating: 0, count: 1000) && Array(tail[(2 * 800)..<(2 * 1000)]) == ramp(1700, 200), "raising the delay by 500 inserts exactly 500 frames of silence")
        // less delay: the oldest waiting frames are dropped, in order
        d.target = 100
        feed(2700, 1000)
        let tail2 = Array(outAll[(2 * 2700)...])
        let idx = stride(from: 0, to: tail2.count, by: 2).map { Int(tail2[$0]) }
        expect(idx.count == 1000 && idx.last == 2700 + 1000 - 1 - 100 && zip(idx, idx.dropFirst()).allSatisfy { $1 == $0 + 1 || $0 == 0 }, "lowering the delay to 100 frames: the stream is continuous again and exactly 100 frames behind")
        d.target = 99_999
        expect(d.target == 5000, "the delay is capped")
    }

    func balancerAndProbe() {
        let d = ZoneBalancer.delays(latencies: ["a": 0.30, "b": 0.80, "c": 0.55])
        expect(abs(d["a"]! - 0.50) < 1e-9 && d["b"]! == 0 && abs(d["c"]! - 0.25) < 1e-9, "\(d)")
        expect(ZoneBalancer.delays(latencies: ["a": 0.1, "b": 5.0], maxDelay: 2)["a"] == 2, "capped")
        expect(ZoneBalancer.delays(latencies: [:]).isEmpty)
        // a whole-second clock that lags the feed by 0.37 s: the ticks give it away
        var s: [(emitted: Double, played: Double, exact: Bool)] = []
        var t = 5.0
        while t < 9 { s.append((t, floor(max(0, t - 0.37)), false)); t += 0.04 }
        let l = LatencyProbe.estimate(s)
        expect(l != nil && abs(l! - 0.37) < 0.05, "whole-second positions still give ±40 ms: \(String(describing: l))")
        let exactSamples: [(emitted: Double, played: Double, exact: Bool)] = (0..<20).map { (i: Int) -> (emitted: Double, played: Double, exact: Bool) in let t = 5 + Double(i) * 0.05; return (t, t - 0.2, true) }
        let e = LatencyProbe.estimate(exactSamples)
        expect(e != nil && abs(e! - 0.2) < 1e-9, "exact positions give the lag directly")
        expect(LatencyProbe.estimate([(1, 0, false), (1.04, 0, false)]) == nil, "no tick, no estimate")
    }

    func upnpDescriptionsAndSOAP() {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>Kitchen</friendlyName><manufacturer>Sonos, Inc.</manufacturer><modelName>Sonos One</modelName><UDN>uuid:RINCON_AAA01400</UDN>
        <deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><UDN>uuid:RINCON_AAA01400_MR</UDN><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/MediaRenderer/RenderingControl/Control</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/MediaRenderer/AVTransport/Control</controlURL></service></serviceList></device></deviceList></device></root>
        """
        let loc = URL(string: "http://192.168.1.50:1400/xml/device_description.xml")!
        let d = UPnPDevice.parse(xml: Data(xml.utf8), location: loc)
        expect(d?.name == "Kitchen" && d?.isSonos == true && d?.rincon == "RINCON_AAA01400" && d?.host == "192.168.1.50" && d?.avTransport.absoluteString == "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control" && d?.renderingControl?.path == "/MediaRenderer/RenderingControl/Control", "\(String(describing: d))")
        expect(UPnPDevice.parse(xml: Data("<root><device><friendlyName>Router</friendlyName><serviceList><service><serviceType>urn:x:WANIP</serviceType><controlURL>/c</controlURL></service></serviceList></device></root>".utf8), location: loc) == nil, "things that cannot play audio are not offered")
        expect(UPnPDevice.parse(xml: Data("not xml".utf8), location: loc) == nil)
        let env = String(decoding: SOAP.envelope(service: UPnPDevice.avTransportType, action: "SetAVTransportURI", args: [("InstanceID", "0"), ("CurrentURI", "http://x/a?b=1&c=2"), ("CurrentURIMetaData", SOAP.didl(title: "A & B <live>", url: "http://x/a?b=1&c=2"))]), as: UTF8.self)
        expect(XMLTree.parse(Data(env.utf8)) != nil && env.contains("b=1&amp;c=2") && !env.contains("<DIDL-Lite") && env.contains("&lt;DIDL-Lite"), "arguments are escaped so the XML stays valid")
        let meta = XMLTree.parse(Data(env.utf8))?.find("CurrentURIMetaData")?.text ?? ""
        expect(XMLTree.parse(Data(meta.utf8))?.find("title")?.text == "A & B <live>", "and the metadata inside survives the round trip")
        expect(SOAP.parseTime("0:01:23")?.seconds == 83 && SOAP.parseTime("0:01:23")?.exact == false && SOAP.parseTime("1:00:00.5")?.seconds == 3600.5 && SOAP.parseTime("1:00:00.5")?.exact == true && SOAP.parseTime("NOT_IMPLEMENTED") == nil)
        expect(SSDP.location(in: "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://10.0.0.5:1400/desc.xml\r\nST: x\r\n\r\n")?.absoluteString == "http://10.0.0.5:1400/desc.xml")
        let fault = FakeRenderer(); fault.failPlay = true
        let dev = d!
        let ep = UPnPEndpoint(device: UPnPDevice(id: dev.id, name: dev.name, manufacturer: "Acme", model: "x", host: "127.0.0.1", avTransport: dev.avTransport, renderingControl: nil), http: fault)
        let r = runAsync { try await ep.start(streamURL: { "http://\($0 ?? "?"):1/a.flac" }, title: "t") }
        if case .failure(let e) = r { expect(e.localizedDescription.contains("Transition not available"), e.localizedDescription) } else { expect(false, "a refusal must surface") }
    }

    func discoveryByBroadcast() {
        let ssdp = UDPResponder { req in String(decoding: req, as: UTF8.self).contains("M-SEARCH") ? Array("HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:9/desc.xml\r\n\r\n".utf8) : nil }
        defer { ssdp.stop() }
        let urls = SSDP.search(timeout: 1, target: "127.0.0.1", port: ssdp.port)
        expect(urls == [URL(string: "http://127.0.0.1:9/desc.xml")!], "\(urls)")
        let tlv: [UInt8] = Array("E".utf8) + Array("NAME".utf8) + [4] + Array("Hifi".utf8) + Array("JSON".utf8) + [4] + Array("9000".utf8)
        let lms = UDPResponder { req in req.first == UInt8(ascii: "e") ? tlv : nil }
        defer { lms.stop() }
        let found = LMSDiscovery.discover(timeout: 1, target: "127.0.0.1", port: lms.port)
        expect(found == [LMSDiscovery.Found(name: "Hifi", host: "127.0.0.1", httpPort: 9000)] && found.first?.url == "http://127.0.0.1:9000", "\(found)")
        expect(LMSDiscovery.parse(Array("E".utf8) + Array("NAME".utf8) + [3], from: "x") == nil, "a truncated answer is ignored")
        expect(LMSDiscovery.parse([1, 2, 3], from: "x") == nil)
    }

    private func renderer(_ id: String, name: String, sonos: Bool = false, latency: Double = 0) -> (UPnPDevice, FakeRenderer) {
        let r = FakeRenderer(); r.latency = latency
        let dev = UPnPDevice(id: "uuid:\(id)", name: name, manufacturer: sonos ? "Sonos, Inc." : "Acme", model: "m", host: "127.0.0.1", avTransport: URL(string: "http://127.0.0.1:1/av")!, renderingControl: URL(string: "http://127.0.0.1:1/rc")!)
        return (dev, r)
    }

    /// The coordinator's own pacing thread feeds the rooms (silence: no renderer is attached); tests just let time pass.
    private func pump(_ zone: ZoneCoordinator, seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func zoneStartsRoomsAndGroupsSonos() {
        let (d1, r1) = renderer("RINCON_A1", name: "Kitchen", sonos: true), (d2, r2) = renderer("RINCON_B2", name: "Study", sonos: true), (d3, r3) = renderer("dlna-3", name: "TV")
        let zone = ZoneCoordinator(format: CastFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2))
        zone.add(UPnPEndpoint(device: d1, http: r1)); zone.add(UPnPEndpoint(device: d2, joins: d1.rincon, http: r2)); zone.add(UPnPEndpoint(device: d3, http: r3), delay: 0.25)
        let failures = try! runAsync { try await zone.start() }.get()
        expect(failures.isEmpty && zone.members.count == 3, "\(failures)")
        let u1 = r1.called("SetAVTransportURI").first?["CurrentURI"] ?? "", u3 = r3.called("SetAVTransportURI").first?["CurrentURI"] ?? ""
        expect(u1.hasPrefix("http://127.0.0.1:") && u1.hasSuffix(".flac") && !r1.called("Play").isEmpty && r1.called("Play").first?["Speed"] == "1", "the coordinator is given the stream: \(u1)")
        expect(r2.called("SetAVTransportURI").first?["CurrentURI"] == "x-rincon:RINCON_A1" && r2.called("Play").isEmpty, "the other Sonos player joins the coordinator instead of getting its own stream")
        expect(u3 != u1 && (r3.called("SetAVTransportURI").first?["CurrentURIMetaData"] ?? "").contains("object.item.audioItem.musicTrack"), "a DLNA room gets its own stream, with metadata")
        expect(zone.member("uuid:dlna-3")?.feed.delaySeconds == 0.25)
        // the stream is really being served
        let c = Collector(); let ses = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        let task = ses.dataTask(with: URL(string: u1)!); task.resume()
        pump(zone, seconds: 0.6)
        expect(c.wait({ c.snapshot.count > 40 }, timeout: 3) && c.snapshot.prefix(4) == Data("fLaC".utf8), "the room can fetch a FLAC stream from this Mac")
        task.cancel(); ses.invalidateAndCancel()
        runAsync { await zone.setVolume(0.4) }.getOrFail()
        expect(r1.called("SetVolume").first?["DesiredVolume"] == "40" && r1.called("SetVolume").first?["Channel"] == "Master")
        runAsync { await zone.stop() }.getOrFail()
        expect(!r1.called("Stop").isEmpty && !r3.called("Stop").isEmpty && !r2.called("BecomeCoordinatorOfStandaloneGroup").isEmpty, "stopping releases every room, and ungroups the joined Sonos player")
        expect(zone.members.isEmpty)
    }

    func zoneSurvivesARoomThatRefuses() {
        let (d1, r1) = renderer("ok", name: "Good"), (d2, r2) = renderer("bad", name: "Bad"); r2.failPlay = true
        let zone = ZoneCoordinator(format: CastFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2))
        zone.add(UPnPEndpoint(device: d1, http: r1)); zone.add(UPnPEndpoint(device: d2, http: r2))
        let f = try! runAsync { try await zone.start() }.get()
        expect(f.count == 1 && f["uuid:bad"]?.contains("refused") == true && zone.members.map(\.endpoint.id) == ["uuid:ok"], "the room that refused is reported and dropped; the others play: \(f)")
        runAsync { await zone.stop() }.getOrFail()
    }

    func zoneAlignsRoomsThatLag() {
        let (d1, r1) = renderer("fast", name: "Fast", latency: 0.30), (d2, r2) = renderer("slow", name: "Slow", latency: 0.80), (d3, r3) = renderer("mid", name: "Mid", latency: 0.55)
        let zone = ZoneCoordinator(format: CastFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2))
        zone.add(UPnPEndpoint(device: d1, http: r1)); zone.add(UPnPEndpoint(device: d2, http: r2)); zone.add(UPnPEndpoint(device: d3, http: r3))
        _ = try! runAsync { try await zone.start() }.get()
        let result = runAsync(timeout: 30) { await zone.align() }
        guard case .success(let r) = result else { expect(false, "align timed out"); return }
        expect(r.latencies.count == 3, "\(r.latencies)")
        let want = ["uuid:fast": 0.50, "uuid:mid": 0.25, "uuid:slow": 0.0]
        for (id, w) in want { expect(abs((r.delays[id] ?? -1) - w) < 0.08, "\(id) delayed \(r.delays[id] ?? -1) s, expected about \(w)") }
        expect(zone.member("uuid:fast")?.feed.delayFrames == Int((r.delays["uuid:fast"]! * 44_100).rounded()), "the delay lines took the new values")
        runAsync { await zone.stop() }.getOrFail()
    }

    func feedDelaysTheStreamExactly() {
        let fmt = CastFormat(sampleRate: 44_100, bitsPerSample: 24, channels: 2)
        let feed = ZoneFeed(format: fmt, path: "/z.flac")
        feed.delayFrames_test(1000)
        let port = try! feed.start(); defer { feed.stop() }
        let c = Collector(); let ses = URLSession(configuration: .ephemeral, delegate: c, delegateQueue: nil)
        let task = ses.dataTask(with: URL(string: "http://127.0.0.1:\(port)/z.flac")!); task.resume()
        expect(c.wait({ feed.hub.subscriberCount == 1 }, timeout: 3))
        let total = 4096 * 3
        var pcm = [Int32](repeating: 0, count: total * 2)
        for i in 0..<total { pcm[i * 2] = Int32(i + 1) << 8; pcm[i * 2 + 1] = -Int32(i + 1) << 8 }
        pcm.withUnsafeBufferPointer { b in var p = 0; while p < total { let n = min(1024, total - p); feed.push(b.baseAddress! + p * 2, frames: n); p += n } }
        let url = dir.appendingPathComponent("feed.flac")
        expect(c.wait({ c.snapshot.count > 1000 && feed.hub.framesPublished >= 3 }, timeout: 3))
        Thread.sleep(forTimeInterval: 0.2)
        try! c.snapshot.write(to: url)
        guard let f = try? LosslessFile(path: url.path) else { expect(false, "the stream is not decodable"); return }
        let got = readAll(f)
        task.cancel(); ses.invalidateAndCancel()
        expect(got.count == total * 2, "\(got.count / 2) frames")
        expect(Array(got[0..<2000]) == [Int32](repeating: 0, count: 2000) && Array(got[2000..<(2000 + 2 * 3000)]) == Array(pcm[0..<6000]), "the room hears 1000 frames of silence, then the music: sample-exact")
        expect(abs(feed.emittedSeconds - Double(total) / 44_100) < 1e-9)
    }

    // MARK: LMS

    private func lmsFlac() -> Data {
        let url = dir.appendingPathComponent("lms.flac")
        do {
            let f = try! AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatInt16, interleaved: true)
            let n = 44_100 * 12
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
            var x: UInt64 = 11
            for i in 0..<(n * 2) { x = x &* 6364136223846793005 &+ 1; b.int16ChannelData![0][i] = Int16(truncatingIfNeeded: Int(x >> 52) + Int(6000 * sin(Double(i / 2) * 0.03))) }
            try! f.write(from: b)
        }
        return try! Data(contentsOf: url)
    }

    private func lmsSetup(_ data: Data, count: Int = 7) -> (FakeLMS, LMSRegistry, LMSProfile) {
        let s = FakeLMS()
        for i in 1...count { s.tracks.append(.init(id: 100 + i, title: "Song \(i)", artist: i <= 4 ? "Ada" : "Bo", album: i <= 4 ? "First" : "Second", track: i, year: 2001 + i, data: data)) }
        let reg = LMSRegistry()
        reg.secrets = MemorySecretStore(); reg.http = s
        reg.defaults = UserDefaults(suiteName: "aureon.lmstest.\(UUID().uuidString.prefix(6))")!
        var p = LMSProfile(); p.name = "Den"; p.url = "http://192.168.1.20:9000"; p.username = s.user
        reg.save(p, password: s.password)
        return (s, reg, p)
    }

    func lmsClientAndPaths() {
        let (s, reg, p) = lmsSetup(Data([1, 2, 3]))
        let c = try! reg.client(for: p)
        let st = try! runAsync { try await c.status() }.get()
        expect(st.version == "9.0.0" && st.songs == 7 && st.lastScan == 1_700_000_000 && !st.scanning, "\(st)")
        let page = try! runAsync { try await c.songs(offset: 0, count: 3) }.get()
        expect(page.total == 7 && page.tracks.count == 3 && page.tracks[0].id == "101", "\(page.tracks.count) of \(page.total)")
        let t = page.tracks[1]
        expect(t.title == "Song 2" && t.artist == "Ada" && t.track == 2 && t.disc == 1 && t.year == 2003 && t.size == 3 && t.suffix == "flac" && t.sampleRate == 44_100 && t.bitDepth == 16 && t.channels == 2 && t.coverID == "cov102", "strings and numbers both read: \(t)")
        expect(try! runAsync { try await c.songs(offset: 6, count: 3) }.get().tracks.count == 1, "the last page is short")
        expect(try! runAsync { try await c.song(id: "105") }.get()?.title == "Song 5" && (try! runAsync { try await c.song(id: "999") }.get()) == nil)
        // wrong password / missing auth
        let bad = LMSClient(urlString: "192.168.1.20:9000/", username: "squeeze", password: "nope", http: s)!
        if case .failure(let e) = runAsync({ try await bad.status() }) { expect(e.localizedDescription.contains("password"), e.localizedDescription) } else { expect(false, "must fail") }
        let notLMS = LMSClient(urlString: "http://x", http: { final class H: HTTPClient, @unchecked Sendable { func send(_ r: URLRequest) async throws -> (Data, Int) { (Data("<html/>".utf8), 200) } }; return H() }())!
        if case .failure(let e) = runAsync({ try await notLMS.status() }) { expect(e.localizedDescription.contains("Lyrion"), e.localizedDescription) } else { expect(false, "must fail") }
        expect(LMSClient(urlString: "   ") == nil && c.base.absoluteString == "http://192.168.1.20:9000" && LMSClient(urlString: "host:9000")?.base.absoluteString == "http://host:9000")
        // paths
        let path = LMSPath.make(profile: "ab12", track: "101", suffix: "flac")
        expect(path == "lms://ab12/101.flac" && LMSPath.parse(path)?.profile == "ab12" && LMSPath.parse(path)?.track == "101" && LMSPath.parse("subsonic://a/b") == nil && RemoteMedia.isRemote(path))
        expect(LMSPath.suffix(forType: "flc") == "flac" && LMSPath.suffix(forType: "alc") == "m4a" && LMSPath.suffix(forType: "aif") == "aiff" && LMSPath.suffix(forType: "mp3") == "mp3")
        // the download carries the credentials
        let f = c.fetcher(trackID: "101", size: 3)
        expect(try! runAsync { try await f.fetch(offset: 1, length: 2) }.get() == Data([2, 3]) && f.headers["Authorization"]?.hasPrefix("Basic ") == true)
    }

    func lmsImportAndPlay() {
        let data = lmsFlac()
        let (s, reg, p) = lmsSetup(data)
        let lib = try! LibraryStore()
        let r1 = try! LMSImporter.run(profile: p, registry: reg, store: lib, pageSize: 3)
        expect(r1.songs == 7 && r1.failed == 0, "\(r1)")
        let t = lib.track(path: LMSPath.make(profile: p.id, track: "103", suffix: "flac"))
        expect(t?.title == "Song 3" && t?.artistLine == "Ada" && t?.releaseTitle == "First" && t?.trackNumber == 3 && t?.year == 2004 && t?.codec == "FLAC" && t?.sampleRate == 44_100 && t?.genres == ["Jazz"], "\(String(describing: t))")
        expect(lib.stats().tracks == 7 && lib.stats().releases == 2, "\(lib.stats())")
        _ = try! LMSImporter.run(profile: p, registry: reg, store: lib, pageSize: 3)
        expect(lib.stats().tracks == 7, "importing twice does not duplicate")
        s.tracks.removeAll { $0.id > 105 }
        let r3 = try! LMSImporter.run(profile: p, registry: reg, store: lib, pageSize: 3)
        expect(r3.removed == 2 && lib.stats().tracks == 5, "\(r3) \(lib.stats())")
        // a progress callback that reaches the total
        var last = (0, 0); let box = NSLock()
        _ = try! LMSImporter.run(profile: p, registry: reg, store: lib, pageSize: 2, progress: { d, t in box.lock(); last = (d, t); box.unlock() })
        expect(last == (5, 5), "\(last)")
        // stopped half way: nothing is removed
        let cancelled = try! LMSImporter.run(profile: p, registry: reg, store: lib, pageSize: 2, cancelled: { true })
        expect(cancelled.songs == 0 && lib.stats().tracks == 5)
        // bad credentials change nothing
        let (s2, reg2, p2) = lmsSetup(data); s2.requireAuth = true
        reg2.save(p2, password: "wrong")
        do { _ = try LMSImporter.run(profile: p2, registry: reg2, store: lib); expect(false, "must throw") } catch { expect(error.localizedDescription.contains("password"), error.localizedDescription) }
        expect(lib.stats().tracks == 5)

        // playback: the original file, byte for byte, through the normal engine
        let shared = LMSRegistry.shared
        shared.secrets = reg.secrets; shared.http = s; shared.defaults = reg.defaults
        shared.save(p, password: s.password)
        defer { shared.remove(p.id) }
        let file = dir.appendingPathComponent("lms.flac")
        let local = readAll(try! LosslessFile(path: file.path))
        let sink = RecordingSink(speed: 20)
        var o = PlayerOptions(); o.sinkFactory = { _ in sink }
        let pl = Player()
        pl.setQueue([LMSPath.make(profile: p.id, track: "101", suffix: "flac"), LMSPath.make(profile: p.id, track: "102", suffix: "flac")]); pl.start(options: o)
        _ = pl.waitUntilFinished(timeout: 20)
        let got = sink.samples, lead = got.firstIndex { $0 != 0 } ?? 0
        expect(pl.status.finished && pl.status.errors.isEmpty, "\(pl.status.errors)")
        expect(got.count >= local.count * 2 && Array(got[lead..<(lead + local.count)]) == local && Array(got[(lead + local.count)..<(lead + 2 * local.count)]) == local, "two Lyrion tracks arrive bit for bit, back to back")
        expect(s.log.filter { $0.hasSuffix("/download") }.count >= 2)
        if case .success(let art) = runAsync({ await MetadataEngine.artwork(path: LMSPath.make(profile: p.id, track: "101", suffix: "flac")) }) { expect(art == Data([0xFF, 0xD8, 0xFF, 1, 2]), "cover art comes from the server") } else { expect(false, "art") }
        expect((try? openLossless(path: LMSPath.make(profile: p.id, track: "999", suffix: "flac"))) == nil && (try? openLossless(path: LMSPath.make(profile: "gone", track: "101", suffix: "flac"))) == nil, "unknown tracks and removed servers fail cleanly")
        s.supportsRange = false
        shared.remove(p.id); shared.save(p, password: s.password)
        let cut: Bool = { guard let f = try? openLossless(path: LMSPath.make(profile: p.id, track: "103", suffix: "flac")) else { return true }; return readAll(f).count < local.count }()
        expect(cut, "a server without range support is refused or cut short, never misread")
    }

    // MARK: bridge

    private final class FakeSource: BridgeSource, @unchecked Sendable {
        var files: [String: URL] = [:]
        var lastSeq: Int64 = 3
        func changes(afterSeq: Int64, limit: Int) -> [LibraryChange] {
            (1...3).filter { Int64($0) > afterSeq }.prefix(limit).map { LibraryChange(seq: Int64($0), revision: 1, kind: "track", uid: "t\($0)", op: "upsert", track: nil, party: nil, release: nil, work: nil) }
        }
        func playlists() -> [BridgePlaylist] { [BridgePlaylist(id: "p1", name: "Evening", tracks: ["t1", "t3"])] }
        func likedIDs() -> [String] { ["t2"] }
        func fileURL(trackID: String) -> URL? { files[trackID] }
    }

    func bridgePairingAndSync() {
        var big = Data(count: 3 * (1 << 20) + 12_345)
        for i in 0..<big.count { big[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 8)) }
        let file = dir.appendingPathComponent("bridge-track.flac"); try! big.write(to: file)
        let src = FakeSource(); src.files = ["t1": file]
        let suite = "aureon.bridgetest.\(UUID().uuidString.prefix(6))"; let keyFolder = dir.appendingPathComponent("bridge-private-\(UUID().uuidString.prefix(6))")
        let reg = BridgeRegistry(); reg.secrets = PrivateFileSecretStore(folder: keyFolder); reg.defaults = UserDefaults(suiteName: suite)!
        let server = BridgeServer(source: src, registry: reg, serviceName: "Test Mac", advertise: false)
        var paired: PairedDevice?; let lk = NSLock()
        server.onPaired = { lk.lock(); paired = $0; lk.unlock() }
        let sp = try! server.start(); defer { server.stop() }
        func ep(_ p: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!) }

        // pairing: wrong code, right code, and the code only works once
        let (token, pp) = try! server.beginPairing()
        expect(token.count == 39 && BridgeServer.parse(token)?.count == 16 && BridgeServer.parse(token.lowercased().replacingOccurrences(of: "-", with: " ")) != nil && BridgeServer.parse("1234") == nil, token)
        let wrong = String(token.dropLast()) + (token.last == "A" ? "B" : "A")
        if case .success = runAsync(timeout: 10, { try await BridgeClient.pair(endpoint: ep(pp), tokenText: wrong, deviceName: "Intruder") }) { expect(false, "a wrong code must not pair") }
        expect(reg.devices.isEmpty, "nothing was paired by the wrong code")
        guard case .success(let creds) = runAsync(timeout: 10, { try await BridgeClient.pair(endpoint: ep(pp), tokenText: token, deviceName: "Ada's iPhone") }) else { expect(false, "pairing with the right code failed"); return }
        expect(reg.devices.count == 1 && reg.devices[0].name == "Ada's iPhone" && reg.verify(id: creds.deviceID, token: creds.token) && !reg.verify(id: creds.deviceID, token: "x") && reg.devices[0].tokenHash != creds.token, "the Mac keeps only a hash of the device token")
        Thread.sleep(forTimeInterval: 0.2)
        lk.lock(); expect(paired?.id == creds.deviceID); lk.unlock()
        expect(!server.isPairing, "one device per code")
        if case .success = runAsync(timeout: 5, { try await BridgeClient.pair(endpoint: ep(pp), tokenText: token, deviceName: "Again") }) { expect(false, "a used code must not work again") }

        // a session
        let client = BridgeClient(endpoint: ep(sp), credentials: creds)
        guard case .success = runAsync(timeout: 10, { try await client.connect() }) else { expect(false, "paired device cannot connect"); return }
        let ch = try! runAsync { try await client.allChanges(after: 0) }.get()
        expect(ch.changes.map(\.uid) == ["t1", "t2", "t3"] && ch.cursor == 3, "\(ch)")
        expect(try! runAsync { try await client.allChanges(after: 2) }.get().changes.map(\.seq) == [3], "only what changed since the cursor")
        let col = try! runAsync { try await client.collections() }.get()
        expect(col == BridgeCollections(playlists: [BridgePlaylist(id: "p1", name: "Evening", tracks: ["t1", "t3"])], liked: ["t2"]), "\(col)")
        let dest = dir.appendingPathComponent("bridge-got.flac"); try? FileManager.default.removeItem(at: dest)
        var lastProgress: (Int64, Int64) = (0, 0)
        let t0 = Date()
        try! runAsync(timeout: 60) { try await client.download(track: "t1", to: dest, progress: { lastProgress = ($0, $1) }) }.get()
        expect((try? Data(contentsOf: dest)) == big && lastProgress == (Int64(big.count), Int64(big.count)), "\(big.count >> 20) MB arrive identical in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        // resume from a partial file
        try! big.prefix(1_500_000).write(to: dest)
        try! runAsync(timeout: 60) { try await client.download(track: "t1", to: dest) }.get()
        expect((try? Data(contentsOf: dest)) == big, "a partial download is resumed, not restarted")
        // not a local file
        if case .failure(let e) = runAsync({ try await client.download(track: "t2", to: self.dir.appendingPathComponent("nope")) }) { expect(e.localizedDescription.contains("not a file"), e.localizedDescription) } else { expect(false, "must refuse") }
        expect(try! runAsync { try await client.changes(after: 0, limit: 1) }.get().changes.count == 1, "the session survives a refused request")
        client.close()

        // removing the device shuts it out; so does the wrong key
        reg.revoke(creds.deviceID)
        let revoked = BridgeClient(endpoint: ep(sp), credentials: creds)
        if case .failure(let e) = runAsync(timeout: 10, { try await revoked.connect() }) { expect(e.localizedDescription.contains("not paired"), e.localizedDescription) } else { expect(false, "a removed device must be refused") }
        var badKey = creds; badKey.key = Data(repeating: 7, count: 32).base64EncodedString()
        let evil = BridgeClient(endpoint: ep(sp), credentials: badKey)
        if case .success = runAsync(timeout: 10, { try await evil.connect() }) { expect(false, "without the key not even the handshake succeeds") }
        // garbage on the plain socket gets nowhere
        let raw = BridgeLink(NWConnection(to: ep(sp), using: .tcp))
        if case .success = runAsync(timeout: 10, { try await raw.start(queue: DispatchQueue(label: "raw")); try await raw.send(.hello, Data("{}".utf8)); _ = try await raw.receive() }) { expect(false, "plain TCP must not be answered") }
        raw.close()
        // the key is a private file, and a new start of the app (a new registry on the same folder) knows the same key and the same paired devices
        let keyFile = keyFolder.appendingPathComponent("bridge.key")
        let perms = { (u: URL) in ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        expect(perms(keyFolder) == 0o700 && perms(keyFile) == 0o600, "the folder is private to the user (0700) and so is the key file (0600): \(String(perms(keyFolder), radix: 8)) \(String(perms(keyFile), radix: 8))")
        let again = BridgeRegistry(); again.secrets = PrivateFileSecretStore(folder: keyFolder); again.defaults = UserDefaults(suiteName: suite)!
        expect(again.bridgeKey == reg.bridgeKey && again.bridgeKey.count == 32, "the key survives a restart")
        guard case .success(let creds2) = runAsync(timeout: 10, { try await BridgeClient.pair(endpoint: ep(sp), tokenText: (try server.beginPairing()).0, deviceName: "Second phone") }) else { return }
        expect(again.verify(id: creds2.deviceID, token: creds2.token), "a device paired before the restart is still known after it")
    }
}

final class Atomic2: @unchecked Sendable { private let l = NSLock(); private var v = false; var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }
extension Result { func getOrFail() { if case .failure(let e) = self { expect(false, "\(e)") } } }
extension ZoneFeed { func delayFrames_test(_ n: Int) { delaySeconds = Double(n) / Double(format.sampleRate) } }
