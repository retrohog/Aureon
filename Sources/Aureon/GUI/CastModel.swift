import SwiftUI
import AVKit

@MainActor
final class CastModel: ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var active: CastOutput?
    @Published private(set) var activeDevice: CastDevice?
    @Published private(set) var state = CastState.idle
    @Published private(set) var message: String?
    @Published var volume = 0.5
    @Published var sampleRate = 44_100 { didSet { UserDefaults.standard.set(sampleRate, forKey: "aureon.cast.rate") } }
    @Published var bits = 24 { didSet { UserDefaults.standard.set(bits, forKey: "aureon.cast.bits") } }

    private let browser = CastBrowser()
    /// Told when the audio has to move to or from the speaker (the player restarts the current track in place).
    var onRouteChange: (() -> Void)?
    /// Told just before a Chromecast session starts (a multi-room zone shares the output and must let go of it).
    var willConnect: (() -> Bool)?

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "aureon.cast.rate") != nil { sampleRate = d.integer(forKey: "aureon.cast.rate") }
        if d.object(forKey: "aureon.cast.bits") != nil { bits = d.integer(forKey: "aureon.cast.bits") }
        browser.onChange = { [weak self] list in Task { @MainActor in self?.devices = list } }
    }

    var isCasting: Bool { active != nil && state.isLive }

    func scan() { guard !scanning else { return }; scanning = true; browser.start() }

    func connect(_ device: CastDevice) {
        if let ok = willConnect, !ok() { return }
        disconnect(quiet: true)
        message = nil
        let out = CastOutput(format: CastFormat(sampleRate: sampleRate, bitsPerSample: bits, channels: 2))
        out.title = "Aureon"; out.artist = "Processed output"
        out.onState = { [weak self, weak out] s in Task { @MainActor in self?.stateChanged(s, from: out) } }
        out.onVolume = { [weak self] v, _ in Task { @MainActor in self?.volume = v } }
        active = out; activeDevice = device; state = .connecting
        out.connect(to: device)
        onRouteChange?()
    }

    private func stateChanged(_ s: CastState, from out: CastOutput?) {
        guard out === active else { return }
        state = s
        switch s {
        case .failed(let m), .closed(let m):
            message = m
            teardown()
            onRouteChange?()
        default: break
        }
    }

    func disconnect(quiet: Bool = false) {
        guard active != nil else { return }
        teardown()
        state = .idle
        if !quiet { message = nil; onRouteChange?() }
    }

    private func teardown() {
        let out = active
        active = nil; activeDevice = nil
        DispatchQueue.global(qos: .utility).async { out?.stop() }
    }

    func setVolume(_ v: Double) { volume = v; active?.controller?.setVolume(v) }

    /// The sink factory the player uses while casting.
    var sinkFactory: ((PlayerOptions) -> AudioSink?)? {
        guard let out = active, isCasting || state == .connecting, let name = activeDevice?.name else { return nil }
        return { _ in CastSink(output: out, name: name) }
    }
}

/// The system's own AirPlay / output route button.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = true
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct CastCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var cast: CastModel

    var body: some View {
        Card(title: "Cast and AirPlay", subtitle: "Send the processed sound to a speaker on your network") {
            HStack(spacing: 12) {
                AirPlayButton().frame(width: 36, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirPlay").font(.system(size: 13, weight: .medium))
                    Note(text: "Choose a HomePod, Apple TV or AirPlay speaker. macOS encodes the stream as Apple Lossless at 44.1 or 48 kHz and applies its own volume; exclusive mode and rate switching do not apply. After choosing, pick “\(m.devices.first { $0.name.lowercased().contains("airplay") }?.name ?? "the AirPlay device")” as the output above if the app does not follow.")
                }
                Spacer()
                PillButton(title: "Refresh outputs", symbol: "arrow.clockwise") { m.refreshDevices() }
            }
            Divider()
            HStack {
                Text("Chromecast and Google Home").font(.system(size: 13, weight: .medium))
                Spacer()
                if cast.isCasting || cast.state == .connecting { PillButton(title: "Stop casting", symbol: "stop.fill") { cast.disconnect() } }
            }
            if cast.devices.isEmpty {
                Note(text: cast.scanning ? "Looking for speakers on this network…" : "No speakers found yet.")
            } else {
                ForEach(cast.devices) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.isAudioOnly ? "hifispeaker" : "tv").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) { Text(d.name); Text(d.model).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        if cast.activeDevice?.id == d.id { Badge(text: stateTitle, color: cast.state == .playing ? .green : .orange) }
                        else { PillButton(title: "Cast here", symbol: "dot.radiowaves.right") { cast.connect(d) }.disabled(cast.state == .connecting) }
                    }
                }
            }
            HStack {
                Picker("Rate", selection: $cast.sampleRate) { Text("44.1 kHz").tag(44_100); Text("48 kHz").tag(48_000); Text("88.2 kHz").tag(88_200); Text("96 kHz").tag(96_000) }.frame(maxWidth: 200).disabled(cast.isCasting)
                Picker("Depth", selection: $cast.bits) { Text("16-bit").tag(16); Text("24-bit").tag(24) }.frame(maxWidth: 160).disabled(cast.isCasting)
            }
            if cast.isCasting {
                HStack {
                    Image(systemName: "speaker.fill")
                    FluidSlider(value: Binding(get: { cast.volume }, set: { cast.setVolume($0) }), tint: .white.opacity(0.9), restingHeight: 4, enabled: true, bubble: { "\(Int($0 * 100))%" }, safe: true)
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
            Note(text: "The speaker is sent one fixed lossless FLAC stream, made from the output of Aureon’s own engine (EQ, upsampling and everything else you switched on), so it is not bit-perfect to the file. Tracks are resampled to the rate chosen here. The speaker adds a few seconds of delay. If macOS asks whether Aureon may accept incoming connections, allow it: the speaker fetches the stream from this Mac.")
            if let msg = cast.message { Note(text: msg, color: .red) }
        }
        .onAppear { cast.scan() }
    }

    private var stateTitle: String {
        switch cast.state {
        case .connecting: "Connecting"; case .launching: "Starting"; case .loading: "Loading"; case .buffering: "Buffering"; case .playing: "Casting"; case .paused: "Paused"
        default: "Idle"
        }
    }
}
