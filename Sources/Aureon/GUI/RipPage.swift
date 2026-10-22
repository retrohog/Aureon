import SwiftUI
import AppKit

struct RipPage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var rip: RipModel
    @StateObject private var timer = Box(0)

    var body: some View {
        PageScaffold(title: "Rip CD", subtitle: rip.toc != nil ? rip.driveName : nil, trailing: {
            PillButton(title: "Rescan", symbol: "arrow.clockwise") { rip.scan() }
            PillButton(title: "Disc image…", symbol: "opticaldisc") { openImage() }
        }) {
            if rip.toc == nil { empty } else { content }
        }
        .onAppear { rip.scan() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in if rip.phase != .ripping { rip.scan() } }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            EmptyExplainer(icon: "opticaldisc", title: rip.error == nil ? "Insert an audio CD" : "The disc could not be read",
                           text: rip.error ?? "Aureon rips an audio CD to FLAC, Apple Lossless or WAV exactly as it is on the disc: every sector is read until it agrees with itself, then checked against the AccurateRip database. Macs with Apple Silicon have no built-in drive; any USB CD drive works. You can also open a BIN/CUE disc image.")
            if !rip.discs.isEmpty { ForEach(rip.discs) { d in PillButton(title: "\(d.driveName) · \(d.toc.audioTracks.count) tracks", symbol: "opticaldisc", filled: true) { rip.use(d) } } }
        }
    }

    @ViewBuilder private var content: some View {
        if let toc = rip.toc {
            VStack(alignment: .leading, spacing: 16) {
                if let e = rip.error { Note(text: e, color: .red) }
                header(toc)
                tracksCard(toc)
                settingsCard
                actions
            }
        }
    }

    private func header(_ toc: CDTOC) -> some View {
        Card(title: "Disc", subtitle: "\(toc.audioTracks.count) audio tracks · \(fmtDuration(Double(toc.totalAudioSectors) / 75)) · MusicBrainz ID \(toc.musicBrainzDiscID)") {
            HStack(spacing: 12) {
                if let c = rip.meta.cover, let img = NSImage(data: c) { Image(nsImage: img).resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8)) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Album").frame(width: 80, alignment: .leading); TextField("Album", text: $rip.meta.album).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Artist").frame(width: 80, alignment: .leading); TextField("Album artist", text: $rip.meta.albumArtist).textFieldStyle(.roundedBorder)
                        TextField("Year", text: $rip.meta.year).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                }
            }
            HStack(spacing: 10) {
                if rip.lookingUp { ProgressView().controlSize(.small); Text("Looking the disc up…").font(.caption).foregroundStyle(.secondary) }
                else if rip.releases.isEmpty { Text("MusicBrainz does not know this disc: type the names in.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Menu("\(rip.releases.count) match\(rip.releases.count == 1 ? "" : "es") on MusicBrainz") {
                        ForEach(rip.releases) { r in Button("\(r.title) — \(r.summary)") { rip.choose(r.id) } }
                    }.fixedSize()
                }
                Spacer()
                Label(rip.arState, systemImage: rip.arPressings == nil ? "questionmark.circle" : "checkmark.seal").font(.caption).foregroundStyle(rip.arPressings == nil ? Color.secondary : Color.green)
            }
        }
    }

    private func tracksCard(_ toc: CDTOC) -> some View {
        Card(title: "Tracks", subtitle: "Untick what you do not want") {
            VStack(spacing: 2) {
                ForEach(toc.audioTracks, id: \.number) { t in
                    let st = rip.tracks[t.number] ?? RipModel.TrackState()
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { rip.tracks[t.number]?.enabled ?? false }, set: { rip.tracks[t.number]?.enabled = $0 })).labelsHidden().disabled(rip.phase == .ripping)
                        Text(String(format: "%02d", t.number)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 24)
                        TextField("Title", text: Binding(get: { rip.meta.tracks[t.number]?.title ?? "" }, set: { rip.meta.tracks[t.number, default: .init(title: "", artist: "")].title = $0 })).textFieldStyle(.plain)
                        TextField("Artist", text: Binding(get: { rip.meta.tracks[t.number]?.artist ?? "" }, set: { rip.meta.tracks[t.number, default: .init(title: "", artist: "")].artist = $0 })).textFieldStyle(.plain).foregroundStyle(.secondary).frame(width: 180)
                        Text(fmtDuration(toc.seconds(of: t))).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                        status(st).frame(width: 210, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private func status(_ st: RipModel.TrackState) -> some View {
        if st.done, let r = st.report {
            HStack(spacing: 5) {
                if let v = r.accurateRip {
                    Image(systemName: v.kind == .accurate ? "checkmark.seal.fill" : (v.kind == .notInDatabase ? "minus.circle" : "exclamationmark.triangle.fill")).foregroundStyle(v.kind == .accurate ? Color.green : (v.kind == .notInDatabase ? Color.secondary : Color.orange))
                    Text(v.kind == .accurate ? "Accurate (\(v.confidence))" : (v.kind == .notInDatabase ? "Not in database" : "No match")).font(.caption)
                } else { Image(systemName: r.perfect ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(r.perfect ? Color.green : Color.orange); Text(r.perfect ? "Read cleanly" : "Re-read").font(.caption) }
                if !r.unresolvedSectors.isEmpty { Text("\(r.unresolvedSectors.count) bad").font(.caption.weight(.semibold)).foregroundStyle(.red) }
            }
        } else if st.progress > 0 { ProgressView(value: st.progress).frame(width: 150) }
    }

    private var settingsCard: some View {
        Card(title: "Settings", subtitle: nil) {
            SegmentedChoice(selection: $rip.format, items: Array(RipFormat.allCases)) { $0.title }
            SegmentedChoice(selection: $rip.options.mode, items: Array(RipMode.allCases)) { $0.title }
            Note(text: rip.options.mode.blurb)
            Toggle("Use the drive's C2 error pointers (\(rip.supportsC2 ? "this drive provides them" : "this drive does not provide them"))", isOn: $rip.options.useC2).disabled(!rip.supportsC2)
            HStack {
                Text("Read offset")
                Stepper(value: Binding(get: { rip.options.readOffset }, set: { rip.setOffset($0) }), in: -3000...3000) { Text("\(rip.options.readOffset > 0 ? "+" : "")\(rip.options.readOffset) samples").monospacedDigit() }
                Link("Find your drive's offset", destination: URL(string: "https://www.accuraterip.com/driveoffsets.htm")!).font(.caption)
            }
            Note(text: "Every drive reads the audio a few samples early or late. The offset (listed for most drives at accuraterip.com) puts the first sample where it belongs; without it nothing will match AccurateRip.")
            HStack {
                Text("Save in"); Text(rip.destination.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(); Button("Choose…") { chooseFolder() }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if rip.phase == .ripping { PillButton(title: "Cancel", symbol: "xmark") { rip.cancel() }; ProgressView().controlSize(.small) }
                else { PillButton(title: "Rip \(rip.enabledTracks.count) track\(rip.enabledTracks.count == 1 ? "" : "s")", symbol: "arrow.down.circle.fill", filled: true) { rip.start() }.disabled(rip.enabledTracks.isEmpty || rip.source == nil) }
                if rip.phase == .finished, let f = rip.outputFolder { PillButton(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.open(f) } }
                if let l = rip.logURL { PillButton(title: "Open log", symbol: "doc.text") { NSWorkspace.shared.open(l) } }
            }
            if let msg = rip.message { Note(text: msg, color: msg.contains("could not be read") ? .orange : .green) }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.message = "Where should ripped CDs be saved?"
        if p.runModal() == .OK, let u = p.url { rip.destination = u }
    }

    private func openImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.init(filenameExtension: "cue")!]; p.message = "Choose a CUE sheet"
        if p.runModal() == .OK, let u = p.url { rip.openImage(u) }
    }
}
