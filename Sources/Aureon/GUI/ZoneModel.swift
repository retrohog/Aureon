import SwiftUI

@MainActor
final class ZoneModel: ObservableObject {
    struct Room: Identifiable, Equatable {
        var id: String
        var name: String
        var kind: ZoneEndpointKind
        var detail: String
    }
    @Published private(set) var rooms: [Room] = []
    @Published var selected: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var active: ZoneCoordinator?
    @Published private(set) var starting = false
    @Published private(set) var aligning = false
    @Published private(set) var message: String?
    @Published var delays: [String: Double] = [:]           // milliseconds, per room
    @Published var volume = 0.5
    @Published var sampleRate = 44_100
    @Published var bits = 24

    private var upnp: [UPnPDevice] = []
    weak var cast: CastModel?
    var onRouteChange: (() -> Void)?

    var isActive: Bool { active?.running == true }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await SSDP.renderers(timeout: 2.5)
            upnp = found
            var list = found.map { Room(id: $0.id, name: $0.name, kind: $0.isSonos ? .sonos : .dlna, detail: "\($0.manufacturer) \($0.model)".trimmingCharacters(in: .whitespaces)) }
            for c in cast?.devices ?? [] where !list.contains(where: { $0.id == c.id }) { list.append(Room(id: c.id, name: c.name, kind: .chromecast, detail: c.model)) }
            rooms = list
            scanning = false
            if list.isEmpty { message = "No speakers answered. Check that this Mac and the speakers are on the same network and that Aureon may use the local network." }
        }
    }

    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    func start() {
        guard !starting, !isActive, !selected.isEmpty else { return }
        if cast?.isCasting == true {
            guard askToProceed(title: "Casting is active", message: "A zone and a single Chromecast session cannot both use the output. Stop casting and start the zone?", proceed: "Stop casting and start zone") else { return }
        }
        starting = true; message = nil
        cast?.disconnect(quiet: true)
        let chosen = rooms.filter { selected.contains($0.id) }
        let zone = ZoneCoordinator(format: CastFormat(sampleRate: sampleRate, bitsPerSample: bits, channels: 2))
        // Sonos: the first chosen player coordinates; the others join it, and Sonos keeps them in sync itself.
        var coordinator: UPnPDevice?
        for r in chosen {
            switch r.kind {
            case .chromecast:
                if let d = cast?.devices.first(where: { $0.id == r.id }) { zone.add(ChromecastEndpoint(device: d), delay: (delays[r.id] ?? 0) / 1000) }
            case .sonos, .sonosMember:
                guard let d = upnp.first(where: { $0.id == r.id }) else { continue }
                if let c = coordinator { zone.add(UPnPEndpoint(device: d, joins: c.rincon)) } else { coordinator = d; zone.add(UPnPEndpoint(device: d), delay: (delays[r.id] ?? 0) / 1000) }
            case .dlna:
                if let d = upnp.first(where: { $0.id == r.id }) { zone.add(UPnPEndpoint(device: d), delay: (delays[r.id] ?? 0) / 1000) }
            }
        }
        active = zone
        Task {
            do {
                let failed = try await zone.start()
                starting = false
                if zone.members.isEmpty { message = failed.values.first ?? "No room could start."; active = nil; await zone.stop() }
                else {
                    if !failed.isEmpty { message = failed.map { id, e in "\(rooms.first { $0.id == id }?.name ?? id): \(e)" }.joined(separator: "\n") }
                    await zone.setVolume(volume)
                    onRouteChange?()
                }
            } catch { starting = false; message = error.localizedDescription; active = nil }
        }
    }

    func stop() {
        guard let z = active else { return }
        active = nil
        Task { await z.stop(); onRouteChange?() }
    }

    func setDelay(_ id: String, ms: Double) {
        delays[id] = ms
        active?.member(id)?.feed.delaySeconds = ms / 1000
    }

    func align() {
        guard let z = active, !aligning else { return }
        aligning = true; message = nil
        Task {
            let r = await z.align()
            for (id, d) in r.delays { delays[id] = (d * 1000).rounded() }
            aligning = false
            message = r.latencies.count < 2 ? "Only \(r.latencies.count) room reports its play position, so there is nothing to compare. Trim the others by ear." : "Measured \(r.latencies.count) rooms: " + r.latencies.map { id, l in "\(rooms.first { $0.id == id }?.name ?? id) \(Int(l * 1000)) ms" }.joined(separator: ", ") + "."
        }
    }

    func setVolume(_ v: Double) { volume = v; if let z = active { Task { await z.setVolume(v) } } }

    var sinkFactory: ((PlayerOptions) -> AudioSink?)? {
        guard let z = active, z.running else { return nil }
        let out = z.output
        return { _ in CastSink(output: out, name: "Zone") }
    }
}

struct ZoneCard: View {
    @EnvironmentObject var zone: ZoneModel
    @EnvironmentObject var cast: CastModel

    var body: some View {
        Card(title: "Multi-room zone", subtitle: "Play the processed sound in several rooms at once: Sonos, DLNA / UPnP renderers and Chromecasts") {
            HStack(spacing: 10) {
                PillButton(title: zone.scanning ? "Searching…" : "Find speakers", symbol: "dot.radiowaves.left.and.right") { zone.scan() }.disabled(zone.scanning || zone.isActive)
                if zone.isActive {
                    PillButton(title: zone.aligning ? "Measuring…" : "Align rooms", symbol: "arrow.left.and.right") { zone.align() }.disabled(zone.aligning)
                    PillButton(title: "Stop zone", symbol: "stop.fill") { zone.stop() }
                } else {
                    PillButton(title: zone.starting ? "Starting…" : "Start zone", symbol: "play.fill", filled: true) { zone.start() }.disabled(zone.selected.isEmpty || zone.starting)
                }
            }
            ForEach(zone.rooms) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { zone.selected.contains(r.id) }, set: { _ in zone.toggle(r.id) })).labelsHidden().disabled(zone.isActive)
                        VStack(alignment: .leading, spacing: 0) { Text(r.name); Text("\(r.kind.rawValue) · \(r.detail)").font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                    }
                    if zone.isActive, zone.selected.contains(r.id) {
                        HStack {
                            Text("Delay").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                            ValueSlider(value: Binding(get: { zone.delays[r.id] ?? 0 }, set: { zone.setDelay(r.id, ms: $0) }), in: 0...2000, step: 1)
                            Text("\(Int(zone.delays[r.id] ?? 0)) ms").monospacedDigit().font(.caption).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            HStack {
                Picker("Rate", selection: $zone.sampleRate) { Text("44.1 kHz").tag(44_100); Text("48 kHz").tag(48_000); Text("96 kHz").tag(96_000) }.frame(maxWidth: 200).disabled(zone.isActive)
                Picker("Depth", selection: $zone.bits) { Text("16-bit").tag(16); Text("24-bit").tag(24) }.frame(maxWidth: 160).disabled(zone.isActive)
            }
            if zone.isActive {
                HStack {
                    Image(systemName: "speaker.fill")
                    FluidSlider(value: Binding(get: { zone.volume }, set: { zone.setVolume($0) }), tint: .white.opacity(0.9), restingHeight: 4, enabled: true, bubble: { "\(Int($0 * 100))%" }, safe: true)
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
            if let m = zone.message { Note(text: m, color: .orange) }
            Note(text: "Sonos players you tick are grouped (the first coordinates) and Sonos keeps them in sync itself. Other rooms each get their own stream with a sample-exact delay: “Align rooms” measures how far each lags (about ±20 ms where the speaker reports its position) and sets the delays; fine-tune by ear with the sliders. AirPlay 2 speakers cannot be zone members: macOS only lets its own output route drive them, so use the AirPlay button above for those. Clocks drift apart slowly; align again in long sessions.")
        }
        .onAppear { zone.cast = cast; if zone.rooms.isEmpty { zone.scan() } }
    }
}
