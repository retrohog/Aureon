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
            HStack(spacing: 8) {
                ForEach(items) { it in
                    let on = it == selection
                    Button { withAnimation(.easeOut(duration: 0.18)) { selection = it } } label: {
                        HStack(spacing: 4) {
                            if let icon { Image(systemName: icon(it)).font(Typo.sans(11, .medium)) }
                            Text(label(it)).font(Typo.sans(12, on ? .semibold : .medium))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                        .background { if on { Slab().fill(Brand.accent).matchedGeometryEffect(id: "chip", in: ns) } else { Slab().fill(Brand.ink.opacity(0.07)) } }
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
            Text(title).microLabel().foregroundStyle(Brand.inkTertiary).padding(.leading, 12)
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
                Text(name).font(Typo.sans(12.5, on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text(count >= 1000 ? "\(count / 1000)k" : "\(count)").font(Typo.mono(10)).foregroundStyle(Brand.inkTertiary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
            .foregroundStyle(on ? Brand.cyan : .primary)
            .background(RoundedRectangle(cornerRadius: Metrics.radius(7), style: .continuous).fill(on ? AnyShapeStyle(Brand.cyan.opacity(0.12)) : AnyShapeStyle(Brand.ink.opacity(hover.v ? 0.06 : 0))))
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
            SearchField(prompt: "Search stations", text: $radio.query, width: 150)
            RuleButton(title: "Add station", symbol: "plus") { adding.v = true }
        }) {
            SectionChips(items: RadioModel.Section.allCases, selection: $radio.section, label: \.rawValue, icon: \.icon)
            upscaleStrip
            HStack(alignment: .top, spacing: 16) {
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
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(Typo.sans(30, .light)).foregroundStyle(Brand.inkSecondary)
                Text(e).foregroundStyle(Brand.inkSecondary).multilineTextAlignment(.center)
                RuleButton(title: "Try again", symbol: "arrow.clockwise") { Task { await radio.load() } }
            }.frame(maxWidth: .infinity).padding(.top, 48)
        } else if radio.loading && radio.stations.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Tuning in…").foregroundStyle(Brand.inkSecondary) }.frame(maxWidth: .infinity).padding(.top, 48)
        } else if radio.stations.isEmpty {
            Text(radio.section == .favorites ? "Tap the heart on a station to keep it here." : radio.section == .mine ? "Add a station with its stream address." : "No stations found.")
                .foregroundStyle(Brand.inkSecondary).frame(maxWidth: .infinity).padding(.top, 48)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(radio.stations) { StationCard(station: $0) }
            }
        }
    }

    /// Radio is lossy. What Aureon can honestly do is resample it once, with a long sinc filter, to the DAC's best rate.
    private var upscaleStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus").font(Typo.sans(16)).foregroundStyle(Brand.gradientDiagonal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic upscaling").font(Typo.sans(12.5, .semibold))
                Text(m.settings.radio.upscale ? "Streams are resampled to the best rate your DAC accepts (up to \(Int(m.settings.radio.maxRate / 1000)) kHz) with a long sinc filter, keeping the system mixer out of the path. It cannot restore detail the broadcaster removed."
                     : "Off: streams play at their own sample rate.").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $m.settings.radio.upscale).toggleStyle(.rule).labelsHidden().controlSize(.small)
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
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RemoteImage(url: station.favicon, seed: station.name, corner: 14, maxPixel: 300, symbol: "dot.radiowaves.left.and.right", fit: station.favicon != nil, label: station.name)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous).strokeBorder(Brand.gradient, lineWidth: playing ? 1.8 : 0))
                if hover.v || playing {
                    Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous))
                    if playing && !hover.v { EqualizerBars(active: m.status.state == .playing, color: .white).frame(width: 22, height: 18) }
                    else { Image(systemName: playing && m.status.state == .playing ? "pause.fill" : "play.fill").font(Typo.serif(18, .regular)).foregroundStyle(.white).transition(.scale(scale: 0.7).combined(with: .opacity)) }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { radio.toggleFavorite(station) } label: {
                    Image(systemName: radio.isFavorite(station) ? "heart.fill" : "heart").font(Typo.sans(11, .semibold))
                        .foregroundStyle(radio.isFavorite(station) ? Brand.pink : .white).padding(8).background(Circle().fill(.black.opacity(0.45)))
                }.buttonStyle(.plain).padding(8).opacity(hover.v || radio.isFavorite(station) ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                if station.isLossless { Text("LOSSLESS").font(Typo.mono(8, .heavy)).tracking(0.6).padding(.horizontal, 4).padding(.vertical, 2).background(Slab().fill(Brand.cyan)).foregroundStyle(.black).padding(8) }
                else if station.bitrate >= 192 { Text("HQ").font(Typo.mono(8, .heavy)).padding(.horizontal, 4).padding(.vertical, 2).background(Slab().fill(Brand.violet)).foregroundStyle(.white).padding(8) }
            }
            .scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.name).font(Typo.sans(12.5, .semibold)).lineLimit(1)
                Text(station.subtitle).font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a station").font(Typo.serif(18, .regular))
            Text("Paste the stream address of an MP3, AAC or FLAC radio stream (http:// or https://).").font(Typo.callout).foregroundStyle(Brand.inkSecondary)
            TextField("Name (optional)", text: $name.v).textFieldStyle(.plain).ruleField()
            TextField("https://example.com/stream.mp3", text: $address.v).textFieldStyle(.plain).ruleField()
            if failed.v { Text("That does not look like a web address.").font(Typo.caption).foregroundStyle(Brand.caution) }
            HStack { Spacer(); Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Add") { if radio.addStation(name: name.v, address: address.v) { radio.section = .mine; done() } else { failed.v = true } }.keyboardShortcut(.defaultAction).buttonStyle(.solid) }
        }
        .padding(24).frame(width: 440)
    }
}

// MARK: - Podcasts

struct PodcastsPage: View {
    @EnvironmentObject var pod: PodcastModel

    var body: some View {
        if let show = pod.selected { ShowDetail(show: show) } else { browse }
    }

    private var browse: some View {
        PageScaffold(title: "Podcasts", subtitle: "Discover shows from every country", trailing: { SearchField(prompt: "Search podcasts", text: $pod.query, width: 160) }) {
            SectionChips(items: PodcastModel.Section.allCases, selection: $pod.section, label: \.rawValue, icon: \.icon)
            HStack(alignment: .top, spacing: 16) {
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
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(Typo.sans(30, .light)).foregroundStyle(Brand.inkSecondary)
                Text(e).foregroundStyle(Brand.inkSecondary)
                RuleButton(title: "Try again", symbol: "arrow.clockwise") { Task { await pod.loadShows() } }
            }.frame(maxWidth: .infinity).padding(.top, 48)
        } else if pod.loading && pod.shows.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(Brand.inkSecondary) }.frame(maxWidth: .infinity).padding(.top, 48)
        } else if pod.shows.isEmpty {
            Text(pod.section == .categories && pod.query.isEmpty ? "Pick a category." : "No shows found.").foregroundStyle(Brand.inkSecondary).frame(maxWidth: .infinity).padding(.top, 48)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: show.artwork, seed: show.name, corner: 12, maxPixel: 360, symbol: "mic")
                .scaleEffect(hover.v ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(show.name).font(Typo.sans(12.5, .semibold)).lineLimit(2)
                Text(show.artist).font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
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
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    RemoteImage(url: pod.feed?.image ?? show.artwork, seed: show.name, corner: 14, maxPixel: 480, symbol: "mic").frame(width: 170, height: 170)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PODCAST").microLabel().foregroundStyle(Brand.cyan)
                        Text(show.name).font(Typo.serif(26, .regular)).tracking(-0.4).lineLimit(3)
                        Text(show.artist).font(Typo.sans(15, .medium)).foregroundStyle(Brand.accent)
                        if let g = show.genre { Text(g).microLabel().foregroundStyle(Brand.inkSecondary) }
                        if let f = pod.feed, !f.summary.isEmpty { Text(f.summary).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(4).padding(.top, 2) }
                    }
                    Spacer(minLength: 0)
                }
                if let e = pod.episodeError { Text(e).font(Typo.callout).foregroundStyle(Brand.caution) }
                if let f = pod.feed {
                    Text("\(f.episodes.count) episodes").font(Typo.serif(17, .regular))
                    LazyVStack(spacing: 2) { ForEach(f.episodes.prefix(100)) { EpisodeRow(ep: $0, show: show) } }
                } else if pod.episodeError == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading episodes…").foregroundStyle(Brand.inkSecondary) }
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
                    Circle().fill(playing ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.ink.opacity(hover.v ? 0.16 : 0.09))).frame(width: 34, height: 34)
                    if let progress { ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small) }
                    else { Image(systemName: playing && m.status.state == .playing ? "waveform" : "play.fill").font(Typo.sans(12, .bold)).foregroundStyle(.white) }
                }
            }.buttonStyle(.plain).help(progress != nil ? "Downloading…" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title).font(Typo.sans(13, .semibold)).lineLimit(2)
                if !ep.summary.isEmpty { Text(ep.summary).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(2) }
                HStack(spacing: 8) {
                    if let d = ep.date { Text(d.formatted(date: .abbreviated, time: .omitted)).microLabel() }
                    if let t = ep.duration { Text(fmtDuration(t)).microLabel() }
                    if let b = ep.bytes { Text(formatBytes(b)).microLabel() }
                }.foregroundStyle(Brand.inkTertiary).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(10), style: .continuous).fill(Brand.ink.opacity(hover.v ? 0.06 : 0)))
        .onHover { hover.v = $0 }
    }
}
