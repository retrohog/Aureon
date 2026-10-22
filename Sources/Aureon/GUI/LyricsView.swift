import SwiftUI

// Lyrics on the Now Playing page: a sing-along view with the line being sung sharp and glowing, the lines around it softly blurred, and the page
// following the song. Words that carry their own times (enhanced LRC, or lyrics Aureon wrote itself) light up one by one.
//
//   • The playhead is read from `ProgressModel`; only a tiny observer view does, and it tells the stage when the *line* changes, so the stage
//     redraws a few times a minute, not thirty times a second.
//   • Between those updates the active line runs on a `TimelineView` that extends the last known playhead by the wall-clock time, so word
//     highlights move smoothly at the display's refresh rate (120 Hz on ProMotion).
//   • Blur, glow and the scroll are skipped when Reduce Motion is on: lines then change brightness only.
//   • Scrolling with the wheel or trackpad is the system's own; the page waits a few seconds after you scroll, and a pill brings you back.

/// The playhead, extended between updates so word highlights do not step. Not observable: views read it inside a `TimelineView`.
final class PlayheadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0.0
    private var stamp = CACurrentMediaTime()
    private var playing = false

    func set(position p: Double, playing now: Bool) {
        lock.lock(); position = p; stamp = CACurrentMediaTime(); playing = now; lock.unlock()
    }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return playing ? position + (CACurrentMediaTime() - stamp) : position
    }
}

/// The line being sung, published only when it changes.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published private(set) var active: Int?
    @Published private(set) var isPlaying = false
    let clock = PlayheadClock()

    func update(position: Double, playing: Bool, lyrics: Lyrics) {
        clock.set(position: position, playing: playing)
        let a = lyrics.activeIndex(at: position)
        if a != active { active = a }
        if playing != isPlaying { isPlaying = playing }
    }

    func reset() { active = nil }
}

// MARK: - The section on the Now Playing page

struct LyricsSection: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var service = LyricsService.shared
    @ObservedObject private var ai = IntelligenceCenter.shared
    @AppStorage("aureon.lyrics.show") private var show = true
    @AppStorage("aureon.lyrics.expanded") private var expanded = true
    @AppStorage("aureon.lyrics.large") private var large = false
    @AppStorage("aureon.lyrics.offerGeneration") private var offerGeneration = true
    /// Height of the Now Playing page, so the large view can fill it.
    var availableHeight: CGFloat = 800

    var body: some View {
        let item = m.focusItem
        let isSong = item != nil && item?.isStream != true
        Group {
            if isSong, show {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if expanded { content }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(radius: 20)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: service.phase)
        .animation(.smooth(duration: 0.3), value: expanded)
        // the lookup is started by the Now Playing page and the Lyrics buttons (LyricsDriver), not from here: this view is empty until it is asked to show
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "quote.bubble").foregroundStyle(m.hero.palette.accent.color)
            Text("Lyrics").kicker().foregroundStyle(.white.opacity(0.75))
            if let l = service.lyrics, service.phase == .ready {
                Text(sourceLine(l)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            if service.upgrading { ProgressView().controlSize(.mini); Text("looking for a timed version").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)) }
            Spacer()
            if expanded, service.phase == .ready, service.lyrics?.synced == true {
                Button { withAnimation(.smooth(duration: 0.35)) { large.toggle() } } label: {
                    Image(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle()).help(large ? "Smaller" : "Larger")
            }
            menu
            Button { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .buttonStyle(IconButtonStyle()).help(expanded ? "Collapse" : "Expand")
        }
        .foregroundStyle(.white)
    }

    private func sourceLine(_ l: Lyrics) -> String {
        var parts = [l.source.isEmpty ? l.origin.rawValue : l.source]
        parts.append(l.wordSynced ? "synced by word" : (l.synced ? "synced" : "not timed"))
        if l.origin == .generated { parts.append("written by Aureon") }
        return parts.joined(separator: " · ")
    }

    private var menu: some View {
        Menu {
            Button("Look Again", systemImage: "arrow.clockwise") { service.reload() }
            Toggle("Look Up Lyrics Online", isOn: $service.onlineLookup)
            if service.canOfferGeneration {
                Button("Write Lyrics by Listening…", systemImage: "waveform.badge.mic") { service.generate() }
            }
            if service.lyrics != nil, service.request?.isLocalFile == true {
                Divider()
                if let r = service.request, TagEditing.isEditable(r.path) { Button("Save in the File's Tags", systemImage: "tag") { service.saveToTags() } }
                Button("Save as .lrc Next to the Song", systemImage: "doc.badge.plus") { service.saveAsLRC() }
            }
            Divider()
            Toggle("Offer to Write Missing Lyrics", isOn: $offerGeneration)
            Button("Hide the Lyrics Panel", systemImage: "eye.slash") { show = false }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Lyrics options")
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        let accent = m.hero.palette.accent.color
        switch service.phase {
        case .idle:
            // the lookup starts as soon as the page is up; this is only seen if it could not (no title yet, or it was cleared)
            HStack(spacing: 10) {
                Text("Lyrics appear here when Aureon has looked for them.").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                PillButton(title: "Look for Lyrics", symbol: "magnifyingglass") { LyricsDriver.start(m) }
            }.frame(minHeight: 40)
        case .loading(let msg):
            status(spinner: true, msg)
        case .ready:
            if let l = service.lyrics {
                if l.synced { LyricsStage(lyrics: l, accent: accent, height: large ? max(520, availableHeight - 170) : 380) }
                else { PlainLyrics(lyrics: l, height: large ? max(520, availableHeight - 170) : 300) }
                footer
            }
        case .instrumental:
            VStack(spacing: 8) {
                Image(systemName: "pianokeys").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.white.opacity(0.6))
                Text("Instrumental").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }.frame(maxWidth: .infinity, minHeight: 90)
        case .missing:
            missing
        case .generating(let f, let msg):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView(value: f).tint(accent).frame(maxWidth: 260)
                    Text("\(Int(f * 100))%").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    PillButton(title: "Cancel", symbol: "xmark") { service.cancelGeneration() }
                }
                Text(msg + "… Aureon is listening to the song with the \(ai.settings.whisperModel.title) speech model, on this Mac. Playback is not affected.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 6)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Look Again", symbol: "arrow.clockwise") { service.reload() }
                    if service.canOfferGeneration { PillButton(title: "Try Writing Them", symbol: "waveform.badge.mic") { service.generate() } }
                }
            }.padding(.vertical, 6)
        }
    }

    private func status(spinner: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text + "…").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
            Spacer()
        }.frame(minHeight: 40)
    }

    /// Nothing anywhere. This is the question: whether to write the lyrics by listening, which only happens if the owner says yes.
    private var missing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No lyrics found for this song").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text(searched).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            if service.request?.isLocalFile == true {
                Text("To add them yourself, put a .lrc file with the song's name next to it" + (service.onlineLookup ? "." : ", or turn on the online lookup."))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            }
            if service.canOfferGeneration, offerGeneration, !service.declined {
                Text("Aureon can write them by listening to the song with a small speech model (Whisper \(ai.settings.whisperModel.title), about \(ai.settings.whisperModel.approxMB) MB, downloaded once). It runs on this Mac only, takes a minute or two, and may make mistakes with fast or layered vocals.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Write the Lyrics", symbol: "waveform.badge.mic", filled: true) { service.generate() }
                    PillButton(title: "Not for This Song", symbol: "xmark") { service.decline() }
                }
            } else {
                HStack(spacing: 8) {
                    if !service.onlineLookup { PillButton(title: "Look Online", symbol: "network") { service.onlineLookup = true } }
                    else { PillButton(title: service.onlineUnreachable ? "Try Again" : "Look Again", symbol: "arrow.clockwise") { service.reload() } }
                    if service.canOfferGeneration { PillButton(title: "Write the Lyrics…", symbol: "waveform.badge.mic") { service.generate() } }
                    else if service.request?.isLocalFile == true, !ai.isActive(.lyricsGeneration) {
                        PillButton(title: "Intelligence Settings", symbol: "brain") { m.tab = .intelligence }
                    }
                }
                if !ai.isActive(.lyricsGeneration), service.request?.isLocalFile == true {
                    Text(ai.isMasterOn ? "Writing lyrics is switched off in Intelligence." : "Intelligence features are off, so lyrics cannot be written by listening.")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var searched: String {
        var places = ["the folder", "the file's tags"]
        if service.onlineLookup && service.isOnlineAllowedNow { places.append("LRCLIB online") }
        let list = places.count == 2 ? places.joined(separator: " and ") : places.dropLast().joined(separator: ", ") + " and " + places.last!
        return "Aureon looked in " + list + "." + (service.onlineUnreachable ? " The online service could not be reached; it will be tried again." : "")
    }

    @ViewBuilder private var footer: some View {
        if let note = service.saveNote {
            Text(note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
        } else if service.unsaved, service.request?.isLocalFile == true {
            HStack(spacing: 8) {
                Text("Written by Aureon. Keep them?").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                if let r = service.request, TagEditing.isEditable(r.path) { PillButton(title: "Save in the File's Tags", symbol: "tag") { service.saveToTags() } }
                PillButton(title: "Save as .lrc", symbol: "doc.badge.plus") { service.saveAsLRC() }
                Spacer(minLength: 0)
            }
        }
    }
}

extension LyricsService {
    /// For the page's wording: whether an online search would run right now.
    var isOnlineAllowedNow: Bool { isOnlineAllowed() }
}

// MARK: - Plain lyrics

private struct PlainLyrics: View {
    let lyrics: Lyrics
    let height: CGFloat

    var body: some View {
        ScrollView(showsIndicators: false) {
            Text(lyrics.plainText)
                .font(.system(size: 17, weight: .medium)).lineSpacing(6).foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }
        .frame(height: height)
        .mask(EdgeFade())
    }
}

private struct EdgeFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - The sing-along stage

struct LyricsStage: View {
    @EnvironmentObject var m: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: Lyrics
    let accent: Color
    let height: CGFloat
    @StateObject private var cursor = LyricsCursor()
    @State private var following = true
    @State private var resume: Task<Void, Never>?

    var body: some View {
        let active = cursor.active
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: height * 0.30)
                        if let first = lyrics.lines.first, first.time > 3 {
                            IntroDots(until: first.time, isActive: active == nil, cursor: cursor, accent: accent).id(-1)
                        }
                        ForEach(lyrics.lines) { line in
                            LyricRow(line: line, relative: relative(line.id, active), ends: line.id == active ? lyrics.wordEnds(ofLine: line.id) : [],
                                     breakEnd: line.isBreak ? lyrics.end(ofLine: line.id) : 0, cursor: cursor, accent: accent, reduceMotion: reduceMotion)
                                .equatable()
                                .id(line.id)
                                .onTapGesture { seek(to: line) }
                        }
                        Color.clear.frame(height: height * 0.5)
                    }
                    .padding(.horizontal, 6)
                }
                .onScrollPhaseChange { _, new in if new == .interacting { userScrolled() } }
                .onChange(of: active) { _, a in if following { scroll(proxy, to: a) } }
                .onChange(of: following) { _, f in if f { scroll(proxy, to: cursor.active) } }
                .onAppear { scroll(proxy, to: cursor.active, animated: false) }
            }
            .frame(height: height)
            .mask(EdgeFade())

            if !following {
                Button {
                    resume?.cancel(); following = true
                } label: {
                    Label("Follow the song", systemImage: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.8))
                }
                .buttonStyle(.plain).foregroundStyle(.white).padding(.bottom, 8).transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            // the playhead reaches the stage through this view only
            PlayheadObserver(lyrics: lyrics, cursor: cursor).frame(width: 0, height: 0)
        }
        .animation(.smooth(duration: 0.25), value: following)
        .onChange(of: lyrics) { _, _ in cursor.reset(); following = true }
    }

    /// How far a line is from the one being sung, limited to what changes how it looks.
    private func relative(_ id: Int, _ active: Int?) -> Int {
        guard let active else { return min(id + 1, 6) }                // before the first line: everything is still to come
        return max(-6, min(6, id - active))
    }

    private func scroll(_ proxy: ScrollViewProxy, to line: Int?, animated: Bool = true) {
        let target = line ?? (lyrics.lines.first.map { $0.time > 3 ? -1 : 0 } ?? 0)
        if animated && !reduceMotion { withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.34)) } }
        else { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.34)) }
    }

    private func userScrolled() {
        following = false
        resume?.cancel()
        resume = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { following = true }
        }
    }

    private func seek(to line: LyricLine) {
        guard !line.isBreak else { return }
        m.player.send(.seekTo(line.time))
        resume?.cancel(); following = true
    }
}

/// Feeds the playhead to the cursor. It re-evaluates with every playhead update, which is why it is nothing but this.
private struct PlayheadObserver: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var progress: ProgressModel
    let lyrics: Lyrics
    @ObservedObject var cursor: LyricsCursor

    var body: some View {
        Color.clear
            .onChange(of: progress.position) { _, p in cursor.update(position: p, playing: m.isActive && m.status.state == .playing, lyrics: lyrics) }
            .onChange(of: m.status.state) { _, _ in cursor.update(position: progress.position, playing: m.isActive && m.status.state == .playing, lyrics: lyrics) }
            .onAppear { cursor.update(position: progress.position, playing: m.isActive && m.status.state == .playing, lyrics: lyrics) }
    }
}

// MARK: - Rows

private struct LyricRow: View, Equatable {
    let line: LyricLine
    /// 0: being sung; negative: already sung; positive: still to come (all limited to ±6).
    let relative: Int
    let ends: [Double]
    let breakEnd: Double
    let cursor: LyricsCursor
    let accent: Color
    let reduceMotion: Bool

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.line.id == b.line.id && a.relative == b.relative && a.accent == b.accent && a.reduceMotion == b.reduceMotion && a.line.text == b.line.text && a.breakEnd == b.breakEnd
    }

    private var isActive: Bool { relative == 0 }
    private var distance: Int { abs(relative) }

    var body: some View {
        Group {
            if line.isBreak {
                BreakDots(start: line.time, end: breakEnd, active: isActive, cursor: cursor, accent: accent)
            } else if isActive, !line.words.isEmpty {
                ActiveWords(line: line, ends: ends, cursor: cursor, reduceMotion: reduceMotion)
            } else {
                Text(line.text)
            }
        }
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(opacity))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isActive || reduceMotion ? 1 : 0.93, anchor: .leading)
        .blur(radius: reduceMotion ? 0 : blur)
        .shadow(color: accent.opacity(isActive && !reduceMotion ? 0.6 : 0), radius: isActive ? 16 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.5), value: relative)
        .contentShape(Rectangle())
        .accessibilityLabel(line.isBreak ? "Instrumental" : line.text)
    }

    private var opacity: Double {
        if isActive { return 1 }
        if relative < 0 { return max(0.22, 0.5 - 0.07 * Double(distance)) }       // sung lines fade away upward
        return max(0.25, 0.62 - 0.08 * Double(distance))
    }

    private var blur: Double { isActive ? 0 : min(5, 0.9 + 0.9 * Double(distance)) }
}

/// The active line when its words have times: each word brightens as it is sung.
private struct ActiveWords: View {
    let line: LyricLine
    let ends: [Double]
    @ObservedObject var cursor: LyricsCursor
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !cursor.isPlaying)) { _ in
            let t = cursor.clock.now()
            Text(attributed(at: t))
        }
    }

    private func attributed(at t: Double) -> AttributedString {
        var out = AttributedString()
        for (i, w) in line.words.enumerated() {
            let end = i < ends.count ? ends[i] : w.start + 0.4
            var f = end > w.start ? (t - w.start) / (end - w.start) : (t >= w.start ? 1 : 0)
            f = max(0, min(1, f))
            f = f * f * (3 - 2 * f)                                              // smoothstep: eases in and out
            var piece = AttributedString(w.text)
            piece.foregroundColor = Color.white.opacity(reduceMotion ? (t >= w.start ? 1 : 0.4) : 0.4 + 0.6 * f)
            out.append(piece)
        }
        return out
    }
}

/// "• • •" for an instrumental stretch: the dots fill as the stretch passes.
private struct BreakDots: View {
    let start: Double, end: Double
    let active: Bool
    @ObservedObject var cursor: LyricsCursor
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active || !cursor.isPlaying)) { _ in
            let t = cursor.clock.now()
            let f = active && end > start ? max(0, min(1, (t - start) / (end - start))) : 0
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let lit = max(0, min(1, f * 3 - Double(i)))
                    Circle().fill(.white.opacity(0.3 + 0.7 * lit)).frame(width: 10, height: 10).scaleEffect(0.8 + 0.4 * lit)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// Before the first line: the same dots, filling up to its start.
private struct IntroDots: View {
    let until: Double
    let isActive: Bool
    let cursor: LyricsCursor
    let accent: Color

    var body: some View {
        BreakDots(start: 0, end: until, active: isActive, cursor: cursor, accent: accent)
    }
}

/// The "Look up lyrics online" switch for the settings page.
struct LyricsSettingsToggle: View {
    @ObservedObject private var service = LyricsService.shared
    var body: some View {
        Toggle("Look up missing lyrics online", isOn: $service.onlineLookup)
    }
}

/// Opens Now Playing at the lyrics of the current song (switching lyrics back on if they were hidden). Songs only: radio has no lyrics.
struct LyricsButton: View {
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var stage: StageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 13
    /// Only one button owns ⌘L: the player bar's.
    var shortcut = true
    var body: some View {
        let item = m.focusItem
        let isSong = item.map { !$0.isStream } ?? false
        Button { stage.showLyrics(m, reduceMotion: reduceMotion) } label: {
            Image(systemName: "quote.bubble").font(.system(size: size)).foregroundStyle(.white)
        }
        .buttonStyle(IconButtonStyle()).disabled(!isSong)
        .keyboardShortcut(shortcut ? KeyboardShortcut("l", modifiers: .command) : nil)
        .help(isSong ? (shortcut ? "Lyrics (⌘L)" : "Lyrics")
              : item == nil ? "Lyrics: play a song first" : "Lyrics: radio streams have none")
        .accessibilityLabel("Show lyrics")
    }
}
