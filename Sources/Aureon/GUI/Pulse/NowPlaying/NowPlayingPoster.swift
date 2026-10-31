import SwiftUI

// Poster: a strict 40 pt grid with nothing bleeding off the edge. On the left a very large bold title (two lines at most, sized to fit its column), the
// artist, album and year, the format tags, and at the foot three lines of the words with the one being sung bright (the credits when the lyrics are off).
// On the right, about 300 pt wide: the cover as a square, two credit rows and the next song. The dock is the one the other layouts share. Paper (a warm
// light) when the theme is light, Night when it is dark.

enum PosterMath {
    /// The grid's margin and gutter, in points at the designed size.
    static let margin: CGFloat = 40

    /// "Now playing · Track 3 of 12": the song's place on its album when the tags say it, otherwise its place in the queue.
    static func label(item: QueueItem?, items: [QueueItem]) -> String {
        guard let item else { return "Now playing" }
        if let n = item.trackNumber, let t = item.trackTotal, t > 0, n > 0, n <= t { return "Now playing · Track \(n) of \(t)" }
        if let i = items.firstIndex(where: { $0.id == item.id }) { return "Now playing · Track \(i + 1) of \(items.count)" }
        return "Now playing"
    }

    /// The point size at which `title` fits `width` × `height` in at most two lines of a bold face with tight tracking. A text-width estimate (the average
    /// advance of a bold glyph is about 0.54 em, and word wrapping wastes a tenth of each line), bounded by the room's height and by 28…190 pt.
    static func titleSize(_ title: String, width: CGFloat, height: CGFloat) -> CGFloat {
        let chars = CGFloat(max(1, title.count))
        let byWidth = 2 * 0.9 * max(1, width) / (chars * 0.54)
        let byHeight = max(1, height) / (2 * 1.2)
        return min(190, max(28, min(byWidth, byHeight)))
    }

    /// The two credit rows of the right column: who produced the song, then the next credit the file has (the label, when a file names one).
    static func creditRows(_ credits: [NPCredit]) -> [NPCredit] {
        var rows: [NPCredit] = []
        if let p = credits.first(where: { $0.label == "Produced by" }) { rows.append(p) }
        for c in credits where rows.count < 2 && !rows.contains(c) { rows.append(c) }
        return rows
    }

    /// The credits for the foot of the left column when the words are off: those the right column does not already show (all of them when that leaves none).
    static func footCredits(_ credits: [NPCredit]) -> [NPCredit] {
        let shown = creditRows(credits)
        let rest = credits.filter { !shown.contains($0) }
        return Array((rest.isEmpty ? credits : rest).prefix(3))
    }

    /// The backdrop: Paper, a warm light, on a light theme; Night, the theme's canvas pulled darker, on a dark one.
    static func backdrop(light: Bool, canvas: RGB) -> RGB {
        light ? canvas.mixed(with: RGB(0.965, 0.935, 0.875), 0.6) : canvas.mixed(with: RGB(0, 0, 0), 0.4)
    }
}

struct NPPoster: View {
    let c: NPCanvas
    @EnvironmentObject var m: PlayerModel
    @EnvironmentObject var info: NPTrackInfo

    private var grid: NPCanvas { var g = c; g.inset = max(28, PosterMath.margin * c.s); return g }

    var body: some View {
        let g = grid
        NPFrame(g, content: { size in
            columns(size, g).padding(.horizontal, g.margin).padding(.top, 14 * g.s)
        }, dock: {
            NPDock(g, seek: .slim, left: { HStack(spacing: 4) { NPActions(size: 44) } }, right: { NPCluster(showsChip: false) })
        })
        .background { PosterBackdrop() }
    }

    private func columns(_ size: CGSize, _ g: NPCanvas) -> some View {
        let s = g.s
        let inner = size.width - 2 * g.margin
        let item = m.focusItem
        let rows = PosterMath.creditRows(info.credits)
        let tags = m.look.showSignalTags
        let plan = NPPosterPlan.make(title: m.focusDisplay?.title ?? "Nothing playing", inner: inner, height: size.height - 14 * s, s: s, credits: rows.count, tags: tags)
        return HStack(alignment: .top, spacing: plan.gutter) {
            VStack(alignment: .leading, spacing: plan.gap) {
                Text(PosterMath.label(item: item, items: m.items)).npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                    .frame(height: plan.labelHeight, alignment: .leading)
                title(plan)
                names(item).frame(height: plan.namesHeight, alignment: .topLeading)
                if tags { NPTags().frame(height: plan.tagsHeight, alignment: .topLeading) }
                NPLyricArea(size: 36, height: plan.lyricHeight)
            }
            .frame(width: plan.leftWidth, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12 * s) {
                NPCover(side: plan.coverSide, radius: 4).layoutProbe("poster.cover")
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6 * s) {
                        ForEach(rows) { l in
                            VStack(alignment: .leading, spacing: 1) { Text(l.label).npFont(12.5).foregroundStyle(Brand.inkSecondary); Text(l.value).npFont(15).lineLimit(1) }
                        }
                    }.frame(height: plan.creditsHeight - 12 * s, alignment: .topLeading)
                }
                Text("Up next").npFont(13).textCase(.uppercase).tracking(0.8).foregroundStyle(Brand.inkSecondary).frame(height: plan.upNextHeader - 6 * s, alignment: .leading)
                ScrollView(showsIndicators: false) { NPUpNext(limit: 5, cover: 44).padding(.bottom, 4) }
                    .frame(height: plan.upNextHeight, alignment: .top)
            }
            .frame(width: plan.rightWidth, alignment: .topLeading)
        }
    }

    private func title(_ plan: NPPosterPlan) -> some View {
        let text = m.focusDisplay?.title ?? "Nothing playing"
        let size = plan.titleSize
        return Text(text).font(Typo.face(size, .bold)).tracking(-size * 0.035).lineSpacing(-size * 0.08).lineLimit(2).minimumScaleFactor(0.6).foregroundStyle(Brand.ink)
            .frame(width: plan.leftWidth, height: plan.titleHeight, alignment: .topLeading).layoutProbe("poster.title")
    }

    private func names(_ item: QueueItem?) -> some View {
        let d = m.focusDisplay
        var tail: [String] = []
        if let item, !item.album.isEmpty { tail.append(item.album) }
        if let y = item?.year { tail.append(String(y)) }
        return (Text(d?.artist ?? "").foregroundColor(Brand.ink) + Text(tail.isEmpty ? "" : ((d?.artist.isEmpty ?? true) ? "" : "  ·  ") + tail.joined(separator: "  ·  ")).foregroundColor(Brand.inkSecondary))
            .npFont(22, .medium).lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// The warm paper or the dark night behind Poster, following the theme.
struct PosterBackdrop: View {
    var body: some View {
        PosterMath.backdrop(light: Theme.current.isLight, canvas: Theme.current.canvasRGB).color.ignoresSafeArea().allowsHitTesting(false)
    }
}
