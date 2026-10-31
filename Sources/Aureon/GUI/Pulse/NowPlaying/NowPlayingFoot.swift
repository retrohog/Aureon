import SwiftUI

// The three lines of words that Poster and Turntable keep at the foot of their text column: the line being sung bright between the one before it and the
// one after. When the lyrics are off, or the song has none that are timed, the same room shows its credits. The choice of lines is a pure function
// (`NPLyricWindow`) so it can be tested; the views only place it.

enum NPLyricWindow {
    struct Lines: Equatable {
        var previous: String?
        var current: String?
        var next: String?
    }

    /// The line being sung with the sung line before it and the line to come, skipping the pauses (empty lines) between them. Before the first line
    /// nothing is current and the first line is the one to come.
    static func lines(_ l: Lyrics, active: Int?) -> Lines {
        let words = l.lines
        func text(_ i: Int) -> String? { words.indices.contains(i) && !words[i].isBreak ? words[i].text : nil }
        guard let active, words.indices.contains(active) else {
            return Lines(previous: nil, current: nil, next: words.first { !$0.isBreak }?.text)
        }
        let before = (0..<active).reversed().first { text($0) != nil }.flatMap(text)
        let after = ((active + 1)..<max(active + 1, words.count)).first { text($0) != nil }.flatMap(text)
        return Lines(previous: before, current: text(active), next: after)
    }

    /// Whether there are timed words to show: lyrics are on, found, timed and not empty.
    static func shows(_ l: Lyrics?, wanted: Bool) -> Bool {
        guard wanted, let l else { return false }
        return l.synced && !l.isEmpty
    }
}

/// Three lines of the song's words (or its credits) at the foot of a text column.
struct NPLyricFoot: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var service = LyricsService.shared
    /// Designed size of a line (scaled to the window).
    var size: CGFloat = 26
    /// The credits to show instead of the words (already chosen by the layout).
    var credits: [NPCredit]
    @Environment(\.npScale) private var s

    var body: some View {
        let lyrics = service.phase == .ready ? service.lyrics : nil
        Group {
            if NPLyricWindow.shows(lyrics, wanted: m.look.showLyrics), let lyrics {
                NPLyricTriplet(lyrics: lyrics, size: size)
            } else if credits.isEmpty {
                NPNoCredits().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                NPCreditsGrid(lines: credits, columns: min(3, max(1, credits.count)), gap: 12)
            }
        }
        .frame(minHeight: 3 * size * 1.38 * s * CGFloat(m.look.lyricSize.scale), alignment: .bottomLeading)
    }
}

/// The three lines themselves. The line is worked out from the same playhead clock the full lyrics use, so it changes on the frame it should; the view
/// redraws only when the line changes.
struct NPLyricTriplet: View {
    let lyrics: Lyrics
    let size: CGFloat
    @EnvironmentObject var m: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.npScale) private var s
    @StateObject private var cursor = LyricsCursor()
    @AppStorage("aureon.lyrics.offset") private var offset = 0.0

    var body: some View {
        let px = size * s * CGFloat(m.look.lyricSize.scale)
        let w = NPLyricWindow.lines(lyrics, active: cursor.active)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: px * 0.38) {
                row(w.previous, px, bright: false)
                row(w.current, px, bright: true)
                row(w.next, px, bright: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : Motion.touch, value: cursor.active)
            PlayheadObserver(lyrics: lyrics, cursor: cursor, offset: offset).frame(width: 0, height: 0)
            FrameSampler(cursor: cursor).frame(width: 0, height: 0)
        }
        .onChangeCompat(of: lyrics) { _, _ in cursor.reset() }
        .layoutProbe("lyrics")
        .accessibilityElement(children: .ignore).accessibilityLabel("Lyrics").accessibilityValue(w.current ?? "")
    }

    private func row(_ text: String?, _ px: CGFloat, bright: Bool) -> some View {
        Text(text ?? " ").font(Typo.face(px * CGFloat(Look.current.textScale), Typo.sansWeight(bright ? .medium : .regular)))
            .foregroundStyle(Brand.ink.opacity(bright ? 1 : 0.38)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The words (or the credits) in the big area of Poster and Turntable

/// The room a layout gives the words: the shared scroller (`LyricsStage`, through `NPLyrics`) in large type when the song has lyrics, and when it has none the
/// album and credits instead, so the area is never blank.
struct NPLyricArea: View {
    let size: CGFloat
    let height: CGFloat
    var centered = false
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo
    @ObservedObject private var service = LyricsService.shared
    @Environment(\.npScale) private var s

    var body: some View {
        let has = m.look.showLyrics && service.phase == .ready && service.lyrics?.isEmpty == false
        Group {
            if has {
                NPLyrics(style: LyricStyle(size: size, centered: centered, gap: size * 0.42, rest: LyricsMotion.focus), height: height)
            } else {
                NPInfoBlock(credits: info.credits)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .topLeading).clipped()
    }
}

/// The album and the credits, in place of words that are not there: what the song is part of, then who made it ("no credits" once, only when there are none).
struct NPInfoBlock: View {
    let credits: [NPCredit]
    var columns = 3
    /// Whether the extra panels may take the free room under the credits.
    var extras = true
    @EnvironmentObject var m: PlayerModel
    @Environment(\.npScale) private var s

    var body: some View {
        let item = m.focusItem
        var facts: [NPCredit] = []
        if let a = item?.album, !a.isEmpty { facts.append(NPCredit(label: "Album", value: a)) }
        if let y = item?.year { facts.append(NPCredit(label: "Year", value: String(y))) }
        if let n = item?.trackNumber, let t = item?.trackTotal, t > 0 { facts.append(NPCredit(label: "Track", value: "\(n) of \(t)")) }
        let all = facts + credits.filter { c in !facts.contains { $0.label == c.label } }
        let grid = VStack(alignment: .leading, spacing: 14 * s) {
            if all.isEmpty { NPNoCredits() }
            else { NPCreditsGrid(lines: Array(all.prefix(9)), columns: columns, gap: 16 * s) }
        }
        // the extra panels only take the room the credits leave
        return ViewThatFits(in: .vertical) {
            if extras { VStack(alignment: .leading, spacing: 18 * s) { grid; NPExtraStack(); Spacer(minLength: 0) } } else { VStack(alignment: .leading, spacing: 0) { grid; Spacer(minLength: 0) } }
            VStack(alignment: .leading, spacing: 0) { grid; Spacer(minLength: 0) }
        }
    }
}
