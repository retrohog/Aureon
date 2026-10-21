import SwiftUI

/// A row of pill-shaped section switches.
struct SectionChips<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var icon: ((T) -> String)? = nil
    @Namespace private var ns

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { it in
                    let on = it == selection
                    Button { withAnimation(.easeOut(duration: 0.18)) { selection = it } } label: {
                        HStack(spacing: 5) {
                            if let icon { Image(systemName: icon(it)).font(.system(size: 11, weight: .medium)) }
                            Text(label(it)).font(.system(size: 12, weight: on ? .semibold : .medium))
                        }
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(on ? Color.black.opacity(0.88) : Color.primary.opacity(0.85))
                        .background { if on { Capsule().fill(Brand.gradient).matchedGeometryEffect(id: "chip", in: ns) } else { Capsule().fill(.white.opacity(0.07)) } }
                        .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.08), lineWidth: 0.8))
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 2)
        }
    }
}

/// A scrolling list of facets (genres, countries, languages, categories) beside a grid.
struct FacetColumn: View {
    let title: String
    let items: [(id: String, name: String, count: Int?)]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).microLabel().foregroundStyle(.tertiary).padding(.leading, 10)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(items, id: \.id) { f in
                        FacetRow(name: f.name, count: f.count, on: f.id == selected) { pick(f.id) }
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 176)
    }
}

struct FacetRow: View {
    let name: String
    let count: Int?
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            HStack {
                Text(name).font(.system(size: 12.5, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text(count >= 1000 ? "\(count / 1000)k" : "\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
            .foregroundStyle(on ? Brand.cyan : .primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? AnyShapeStyle(Brand.cyan.opacity(0.12)) : AnyShapeStyle(Color.white.opacity(hover.v ? 0.06 : 0))))
        }.buttonStyle(.plain).onHover { hover.v = $0 }
    }
}

// MARK: - Radio

struct RadioPage: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var radio: RadioModel
    @StateObject private var adding = Box(false)

    var body: some View {
        PageScaffold(title: "Radio", subtitle: "Free stations from around the world", trailing: {
            SearchPill(prompt: "Search stations", text: $radio.query, width: 150)
            PillButton(title: "Add station", symbol: "plus") { adding.v = true }
        }) {
            SectionChips(items: RadioModel.Section.allCases, selection: $radio.section, label: \.rawValue, icon: \.icon)
            upscaleStrip
            HStack(alignment: .top, spacing: 18) {
                if [.genre, .location, .language].contains(radio.section) && radio.query.isEmpty {
                    FacetColumn(title: radio.section == .genre ? "Genres" : radio.section == .location ? "Countries" : "Languages",
                                items: radio.facets.map { ($0.id, $0.name, $0.count) }, selected: radio.facet?.id) { id in radio.facet = radio.facets.first { $0.id == id } }
                }
                VStack(alignment: .leading, spacing: 12) { stations }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task { if radio.stations.isEmpty { await radio.load() } }
        .sheet(isPresented: $adding.v) { AddStationSheet(done: { adding.v = false }).environmentObject(radio) }
    }

    @ViewBuilder private var stations: some View {
        if let e = radio.error {
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PillButton(title: "Try again", symbol: "arrow.clockwise") { Task { await radio.load() } }
            }.frame(maxWidth: .infinity).padding(.top, 50)
        } else if radio.loading && radio.stations.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Tuning in…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.top, 50)
        } else if radio.stations.isEmpty {
            Text(radio.section == .favorites ? "Tap the heart on a station to keep it here." : radio.section == .mine ? "Add a station with its stream address." : "No stations found.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 50)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(radio.stations) { StationCard(station: $0) }
            }
        }
    }

    /// Radio is lossy. What Aureon can honestly do is resample it once, with a long sinc filter, to the DAC's best rate.
    private var upscaleStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 16)).foregroundStyle(Brand.gradientDiagonal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic upscaling").font(.system(size: 12.5, weight: .semibold))
                Text(m.settings.radio.upscale ? "Streams are resampled to the best rate your DAC accepts (up to \(Int(m.settings.radio.maxRate / 1000)) kHz) with a long sinc filter, keeping the system mixer out of the path. It cannot restore detail the broadcaster removed."
                     : "Off: streams play at their own sample rate.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $m.settings.radio.upscale).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(12).panel(radius: 14)
    }
}

struct StationCard: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var radio: RadioModel
    let station: RadioStation
    @StateObject private var hover = Box(false)

    var body: some View {
        let playing = m.current?.station?.id == station.id && m.isActive
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RemoteImage(url: station.favicon, seed: station.name, corner: 14, maxPixel: 300, symbol: "dot.radiowaves.left.and.right", fit: station.favicon != nil, label: station.name)
                    .shadow(color: playing ? Brand.violet.opacity(0.6) : .black.opacity(hover.v ? 0.5 : 0.28), radius: playing ? 14 : (hover.v ? 14 : 7), y: playing ? 0 : 4)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.gradient, lineWidth: playing ? 1.8 : 0))
                if hover.v || playing {
                    Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if playing && !hover.v { EqualizerBars(active: m.status.state == .playing, color: .white).frame(width: 22, height: 18) }
                    else { Image(systemName: playing && m.status.state == .playing ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white).transition(.scale(scale: 0.7).combined(with: .opacity)) }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { radio.toggleFavorite(station) } label: {
                    Image(systemName: radio.isFavorite(station) ? "heart.fill" : "heart").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(radio.isFavorite(station) ? Brand.pink : .white).padding(6).background(Circle().fill(.black.opacity(0.45)))
                }.buttonStyle(.plain).padding(6).opacity(hover.v || radio.isFavorite(station) ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                if station.isLossless { Text("LOSSLESS").font(.system(size: 8, weight: .heavy, design: .monospaced)).tracking(0.6).padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Brand.cyan)).foregroundStyle(.black).padding(7) }
                else if station.bitrate >= 192 { Text("HQ").font(.system(size: 8, weight: .heavy, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Brand.violet)).foregroundStyle(.white).padding(7) }
            }
            .scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(station.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if playing { m.togglePlay() } else { radio.onPlay?(station) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
        .contextMenu {
            Button("Play") { radio.onPlay?(station) }
            Button(radio.isFavorite(station) ? "Remove from Favorites" : "Add to Favorites") { radio.toggleFavorite(station) }
            if station.isUserAdded { Button("Remove Station", role: .destructive) { radio.remove(station) } }
        }
    }
}

struct AddStationSheet: View {
    @EnvironmentObject var radio: RadioModel
    let done: () -> Void
    @StateObject private var name = Box("")
    @StateObject private var address = Box("")
    @StateObject private var failed = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a station").font(.system(size: 18, weight: .semibold))
            Text("Paste the stream address of an MP3, AAC or FLAC radio stream (http:// or https://).").font(.callout).foregroundStyle(.secondary)
            TextField("Name (optional)", text: $name.v).textFieldStyle(.roundedBorder)
            TextField("https://example.com/stream.mp3", text: $address.v).textFieldStyle(.roundedBorder)
            if failed.v { Text("That does not look like a web address.").font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Add") { if radio.addStation(name: name.v, address: address.v) { radio.section = .mine; done() } else { failed.v = true } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(22).frame(width: 440)
    }
}

// MARK: - Podcasts

struct PodcastsPage: View {
    @EnvironmentObject var pod: PodcastModel

    var body: some View {
        if let show = pod.selected { ShowDetail(show: show) } else { browse }
    }

    private var browse: some View {
        PageScaffold(title: "Podcasts", subtitle: "Discover shows from every country", trailing: { SearchPill(prompt: "Search podcasts", text: $pod.query, width: 160) }) {
            SectionChips(items: PodcastModel.Section.allCases, selection: $pod.section, label: \.rawValue, icon: \.icon)
            HStack(alignment: .top, spacing: 18) {
                if pod.query.isEmpty && pod.section == .languages {
                    FacetColumn(title: "Languages", items: PodcastLanguage.all.map { ($0.name, $0.name, nil) }, selected: pod.language) { pod.language = $0 }
                } else if pod.query.isEmpty && pod.section == .categories {
                    FacetColumn(title: "Categories", items: PodcastGenre.allCases.map { (String($0.rawValue), $0.title, nil) }, selected: pod.genre.map { String($0.rawValue) }) { id in pod.genre = Int(id).flatMap(PodcastGenre.init) }
                }
                VStack(alignment: .leading, spacing: 12) { shows }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task { if pod.shows.isEmpty { await pod.loadShows() } }
    }

    @ViewBuilder private var shows: some View {
        if let e = pod.error {
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(e).foregroundStyle(.secondary)
                PillButton(title: "Try again", symbol: "arrow.clockwise") { Task { await pod.loadShows() } }
            }.frame(maxWidth: .infinity).padding(.top, 50)
        } else if pod.loading && pod.shows.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.top, 50)
        } else if pod.shows.isEmpty {
            Text(pod.section == .categories && pod.query.isEmpty ? "Pick a category." : "No shows found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 50)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(pod.shows) { ShowCard(show: $0) }
            }
        }
    }
}

struct ShowCard: View {
    @EnvironmentObject var pod: PodcastModel
    let show: PodcastShow
    @StateObject private var hover = Box(false)
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: show.artwork, seed: show.name, corner: 12, maxPixel: 360, symbol: "mic")
                .shadow(color: .black.opacity(hover.v ? 0.5 : 0.28), radius: hover.v ? 14 : 7, y: hover.v ? 7 : 3).scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(show.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(show.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { pod.selected = show }
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover.v = h } }
    }
}

struct ShowDetail: View {
    @EnvironmentObject var pod: PodcastModel
    let show: PodcastShow

    var body: some View {
        PageScaffold(title: "", back: { pod.selected = nil }, backTitle: "Podcasts") {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 22) {
                    RemoteImage(url: pod.feed?.image ?? show.artwork, seed: show.name, corner: 14, maxPixel: 480, symbol: "mic").frame(width: 170, height: 170).shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PODCAST").microLabel().foregroundStyle(Brand.cyan)
                        Text(show.name).font(.system(size: 26, weight: .bold)).tracking(-0.4).lineLimit(3)
                        Text(show.artist).font(.system(size: 15, weight: .medium)).foregroundStyle(Brand.accent)
                        if let g = show.genre { Text(g).microLabel().foregroundStyle(.secondary) }
                        if let f = pod.feed, !f.summary.isEmpty { Text(f.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4).padding(.top, 2) }
                    }
                    Spacer(minLength: 0)
                }
                if let e = pod.episodeError { Text(e).font(.callout).foregroundStyle(.orange) }
                if let f = pod.feed {
                    Text("\(f.episodes.count) episodes").font(.system(size: 17, weight: .semibold))
                    LazyVStack(spacing: 2) { ForEach(f.episodes.prefix(100)) { EpisodeRow(ep: $0, show: show) } }
                } else if pod.episodeError == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading episodes…").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var pod: PodcastModel
    @EnvironmentObject var m: PlayerModel
    let ep: PodcastEpisode
    let show: PodcastShow
    @StateObject private var hover = Box(false)

    var body: some View {
        let progress = pod.downloads[ep.id]
        let playing = m.current?.title == ep.title && m.isActive
        HStack(alignment: .top, spacing: 12) {
            Button { pod.play(ep, of: show) } label: {
                ZStack {
                    Circle().fill(playing ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.white.opacity(hover.v ? 0.16 : 0.09))).frame(width: 34, height: 34)
                    if let progress { ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small) }
                    else { Image(systemName: playing && m.status.state == .playing ? "waveform" : "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(playing ? .black : .white) }
                }
            }.buttonStyle(.plain).help(progress != nil ? "Downloading…" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if !ep.summary.isEmpty { Text(ep.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 8) {
                    if let d = ep.date { Text(d.formatted(date: .abbreviated, time: .omitted)).microLabel() }
                    if let t = ep.duration { Text(fmtDuration(t)).microLabel() }
                    if let b = ep.bytes { Text(formatBytes(b)).microLabel() }
                }.foregroundStyle(.tertiary).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover.v ? 0.06 : 0)))
        .onHover { hover.v = $0 }
    }
}
