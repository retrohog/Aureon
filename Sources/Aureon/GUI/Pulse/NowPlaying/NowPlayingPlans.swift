import SwiftUI

// Where everything goes in Poster and Turntable, worked out as plain numbers from the room the layout has: no spacers that hide how much is left over.
// The views place exactly these frames, and the tests hold them to "nothing overlaps, nothing is left empty" at any window size.

/// How tall the quality strip is for the width it has: one row when it fits, the stacked form when it does not.
enum QualityStripMetrics {
    static let wideHeight: CGFloat = 58, stackedHeight: CGFloat = 124, wideNeeds: CGFloat = 840
    static func height(width: CGFloat) -> CGFloat { width >= wideNeeds ? wideHeight : stackedHeight }
}

/// Cover flow (Carousel): vertical zones that cannot overlap. The cover row takes what the names, the tag row and the words leave; neighbours scale to about 70 %,
/// 50 % and 36 % with fading opacity, one each side on narrow windows, two on medium ones, three on wide ones. Without lyrics the words shrink to one line and the
/// cover row gets the height back.
struct NPCoverFlowPlan: Equatable {
    var gap: CGFloat
    var coverRow: CGFloat, centre: CGFloat
    var namesHeight: CGFloat, tagsHeight: CGFloat, lyricsHeight: CGFloat
    var perSide: Int
    var width: CGFloat
    static let scales: [CGFloat] = [1, 0.7, 0.5, 0.36]
    static let opacities: [Double] = [1, 0.72, 0.46, 0.28]

    var offsets: [Int] { (-perSide...perSide).map { $0 } }
    func side(_ o: Int) -> CGFloat { centre * Self.scales[min(abs(o), 3)] }
    func opacity(_ o: Int) -> Double { Self.opacities[min(abs(o), 3)] }
    /// Horizontal offset of a neighbour's centre from the middle of the row.
    func x(_ o: Int) -> CGFloat {
        guard o != 0 else { return 0 }
        let step: CGFloat = 18
        var d = centre / 2 + step
        if abs(o) > 1 { for k in 1..<abs(o) { d += side(k) + step } }
        d += side(o) / 2
        return o < 0 ? -d : d
    }
    /// Frames of the zones from the top, for tests: (y, height).
    var zones: [(y: CGFloat, h: CGFloat)] {
        var y: CGFloat = 0, out: [(CGFloat, CGFloat)] = []
        for h in [coverRow, namesHeight, tagsHeight, lyricsHeight] { out.append((y, h)); y += h + gap }
        return out
    }

    static func make(width: CGFloat, height: CGFloat, s: CGFloat, lyrics: Bool) -> NPCoverFlowPlan {
        let gap = 12 * s
        let names = 64 * s, tags: CGFloat = 44
        let lines = height >= 640 * s + 100 ? 5 : 3
        let words = lyrics ? CGFloat(lines) * 40 * s + 8 : 28 * s
        let row = max(110, height - names - tags - words - 3 * gap)
        var centre = min(row, width * 0.42)
        var per = width < 1000 ? 1 : (width < 1500 ? 2 : 3)
        // neighbours must fit beside the centre cover
        func needed(_ n: Int, _ c: CGFloat) -> CGFloat { c + 2 * (1...max(1, n)).reduce(CGFloat(0)) { $0 + c * scales[$1] + 18 } }
        while per > 1 && needed(per, centre) > width { per -= 1 }
        while needed(per, centre) > width && centre > 110 { centre -= 10 }
        return NPCoverFlowPlan(gap: gap, coverRow: row, centre: centre, namesHeight: names, tagsHeight: tags, lyricsHeight: words, perSide: per, width: width)
    }
    func used(height: CGFloat) -> Double { Double((coverRow + namesHeight + tagsHeight + lyricsHeight + 3 * gap) / height) }
}

enum NPTitleFit {
    /// The largest size at which `text` fits `width` in at most two lines (an average bold glyph is 0.54 em wide; wrapping wastes about 8 % of a line), with
    /// the lines it then takes and the height of exactly those lines: the block is never taller than its text, so no blank band is left under a short title.
    static func fit(_ text: String, width: CGFloat, maxHeight: CGFloat, maxSize: CGFloat = 190, minSize: CGFloat = 26) -> (size: CGFloat, lines: Int, height: CGFloat) {
        let chars = CGFloat(max(1, text.count))
        var size = maxSize
        while size > minSize {
            let lines = Int((chars * 0.54 * size / (0.92 * max(1, width))).rounded(.up))
            if lines <= 2, CGFloat(max(1, lines)) * size * 1.12 <= maxHeight { return (size, max(1, lines), CGFloat(max(1, lines)) * size * 1.12) }
            size -= 2
        }
        return (minSize, min(2, max(1, Int((chars * 0.54 * minSize / (0.92 * max(1, width))).rounded(.up)))), minSize * 1.12 * CGFloat(min(2, max(1, Int((chars * 0.54 * minSize / (0.92 * max(1, width))).rounded(.up))))))
    }
}

/// Poster: the title and its names over the words on the left, the cover, credits and the queue on the right.
struct NPPosterPlan: Equatable {
    var leftWidth: CGFloat, rightWidth: CGFloat, gutter: CGFloat
    var titleSize: CGFloat, titleHeight: CGFloat
    var labelHeight: CGFloat, namesHeight: CGFloat, tagsHeight: CGFloat, gap: CGFloat
    var lyricHeight: CGFloat
    var coverSide: CGFloat, creditsHeight: CGFloat, upNextHeader: CGFloat, upNextHeight: CGFloat, upNextRows: Int
    var rowHeight: CGFloat

    /// `inner` is the width between the margins, `height` the room above the dock, `s` the layout's scale.
    static func make(title: String, inner: CGFloat, height: CGFloat, s: CGFloat, credits: Int, tags: Bool) -> NPPosterPlan {
        let gutter = max(24, 40 * s)
        let rightMax = min(max(inner * 0.34, 230 * s), 440 * s)
        let gap = 8 * s, row = 58 * s
        let label = 18 * s, names = 32 * s
        let creditsH = credits > 0 ? CGFloat(min(2, credits)) * 40 * s + 12 * s : 0
        let header = 24 * s
        // right column: the cover as large as the column allows while three queue rows still fit under the credits
        var cover = min(rightMax, max(120 * s, 0.46 * height))
        cover = min(cover, max(100, height - creditsH - header - 12 * s - 3 * row))
        // the column is as wide as its cover (a square), so the grid's margins stay equal and the words get the rest
        let right = max(cover, 200 * s)
        let left = max(160, inner - gutter - right)
        let tagH = tags ? QualityStripMetrics.height(width: left) + 4 * s : 0
        let queue = max(0, height - cover - 12 * s - creditsH - header)
        let rows = max(0, min(5, Int(queue / row)))
        // left column: the title takes about a quarter of the window at most, then the names, the tags and all that is left goes to the words
        let windowHeight = height + 190 * s
        let t = NPTitleFit.fit(title, width: left, maxHeight: min(0.28 * windowHeight, max(60, height * 0.42)), maxSize: 190 * s)
        let used = label + t.height + names + tagH + gap * (tags ? 4 : 3)
        return NPPosterPlan(leftWidth: left, rightWidth: right, gutter: gutter, titleSize: t.size, titleHeight: t.height, labelHeight: label, namesHeight: names, tagsHeight: tagH, gap: gap,
                            lyricHeight: max(60, height - used), coverSide: cover, creditsHeight: creditsH, upNextHeader: header, upNextHeight: queue, upNextRows: rows, rowHeight: row)
    }

    /// The share of each column that holds something (the rest is margin): the test wants it high.
    func leftUsed(height: CGFloat) -> CGFloat { (labelHeight + titleHeight + namesHeight + tagsHeight + lyricHeight + gap * (tagsHeight > 0 ? 4 : 3)) / max(1, height) }
    func rightUsed(height: CGFloat) -> CGFloat { (coverSide + 12 * rowHeight / 58 + creditsHeight + upNextHeader + CGFloat(upNextRows) * rowHeight) / max(1, height) }
}

/// Turntable: the deck as large as its column allows, centred; the title, names, words and the queue on the right.
struct NPTurntablePlan: Equatable {
    var deckSide: CGFloat, leftWidth: CGFloat, rightWidth: CGFloat, gutter: CGFloat
    var showsInfo: Bool, infoHeight: CGFloat
    var titleSize: CGFloat, titleHeight: CGFloat
    var labelHeight: CGFloat, namesHeight: CGFloat, tagsHeight: CGFloat, gap: CGFloat
    var lyricHeight: CGFloat
    var upNextHeader: CGFloat, upNextRows: Int, upNextHeight: CGFloat, rowHeight: CGFloat

    static func make(title: String, inner: CGFloat, height: CGFloat, s: CGFloat, tags: Bool) -> NPTurntablePlan {
        let gutter = max(28, 48 * s)
        let gap = 8 * s, row = 58 * s
        let maxLeft = inner * 0.5
        let infoH = 96 * s
        let showsInfo = height - maxLeft >= infoH + 12 * s
        let side = showsInfo ? maxLeft : min(maxLeft, height)
        let right = max(200, inner - gutter - side)
        let label = 18 * s, names = 30 * s
        let tagH = tags ? QualityStripMetrics.height(width: right) + 4 * s : 0
        let header = 24 * s
        let rows = height >= 600 * s ? 3 : 2
        let queue = header + CGFloat(rows) * row + gap
        let windowHeight = height + 190 * s
        let t = NPTitleFit.fit(title, width: right, maxHeight: min(0.2 * windowHeight, max(56, height * 0.3)), maxSize: 120 * s)
        let used = label + t.height + names + tagH + gap * (tags ? 4 : 3) + queue
        return NPTurntablePlan(deckSide: side, leftWidth: side, rightWidth: right, gutter: gutter, showsInfo: showsInfo, infoHeight: showsInfo ? infoH : 0, titleSize: t.size, titleHeight: t.height,
                               labelHeight: label, namesHeight: names, tagsHeight: tagH, gap: gap, lyricHeight: max(60, height - used), upNextHeader: header, upNextRows: rows, upNextHeight: queue, rowHeight: row)
    }

    func rightUsed(height: CGFloat) -> CGFloat { (labelHeight + titleHeight + namesHeight + tagsHeight + lyricHeight + upNextHeight + gap * (tagsHeight > 0 ? 4 : 3)) / max(1, height) }
    func leftUsed(height: CGFloat) -> CGFloat { (deckSide + (showsInfo ? infoHeight + 12 : 0)) / max(1, height) }
}

/// Classic: cover, title and words, and the queue. A wide, short window puts the cover left, the title and words right, and the queue as a strip of cards
/// across the foot; a tall window keeps two columns and puts the queue as a list at the foot of the right one. The cover is a square as large as what is left.
struct NPClassicPlan: Equatable {
    var wide: Bool
    var gutter: CGFloat, gap: CGFloat
    var coverSide: CGFloat
    /// Height of the row of cover and words (wide), and of the strip under it.
    var topHeight: CGFloat, stripHeight: CGFloat, stripCards: Int
    var rightWidth: CGFloat
    var tagsHeight: CGFloat
    var listRows: Int, listHeight: CGFloat
    var titleHeight: CGFloat

    static func make(inner: CGFloat, height: CGFloat, s: CGFloat, tags: Bool, queued: Int) -> NPClassicPlan {
        let gutter = max(32, 56 * s), gap = 20 * s
        let wide = inner / max(1, height) >= 1.55
        let titleH = 66 * s + 32 * s
        if wide {
            let cards = max(0, min(5, min(queued, Int(inner / (230 * s)))))
            let strip = cards > 0 ? 28 * s + 64 * s : 0
            let top = height - strip - (cards > 0 ? gap : 0)
            let cover = max(120, min(top, inner * 0.40))
            let right = max(200, inner - gutter - cover)
            let tagH = tags ? QualityStripMetrics.height(width: right) + 4 * s : 0
            return NPClassicPlan(wide: true, gutter: gutter, gap: gap, coverSide: cover, topHeight: top, stripHeight: strip, stripCards: cards, rightWidth: right, tagsHeight: tagH, listRows: 0, listHeight: 0, titleHeight: titleH)
        }
        let cover = max(120, min(inner * 0.42, height))
        let right = max(200, inner - gutter - cover)
        let tagH = tags ? QualityStripMetrics.height(width: right) + 4 * s : 0
        let rows = max(0, min(4, min(queued, Int((height * 0.3) / (58 * s)))))
        return NPClassicPlan(wide: false, gutter: gutter, gap: gap, coverSide: cover, topHeight: height, stripHeight: 0, stripCards: 0, rightWidth: right, tagsHeight: tagH, listRows: rows, listHeight: rows > 0 ? 28 * s + CGFloat(rows) * 58 * s : 0, titleHeight: titleH)
    }

    /// The words get what the title, the quality strip and the queue leave.
    func wordsHeight(height: CGFloat, tabsHeight: CGFloat) -> CGFloat {
        let used = titleHeight + tagsHeight + tabsHeight + gap * 2 + (wide ? 0 : listHeight)
        return max(60, (wide ? topHeight : height) - used)
    }

    /// The share of the height that holds something. Wide: the top row is cover and words side by side, so it is full by construction; the strip adds its own.
    func used(height: CGFloat, tabsHeight: CGFloat) -> CGFloat {
        if wide { return (topHeight + stripHeight + (stripCards > 0 ? gap : 0)) / max(1, height) }
        return max(coverSide, titleHeight + tagsHeight + tabsHeight + wordsHeight(height: height, tabsHeight: tabsHeight) + listHeight + gap * 2) / max(1, height)
    }
}

/// Chillax: the cover and title on top, the queue as a grid of cards under them, as many as fit up to fifteen. The rows come from the height that is left, the
/// columns from the width, and the cover takes what the shelf does not need.
struct NPChillaxPlan: Equatable {
    var coverSide: CGFloat
    var columns: Int, rows: Int, limit: Int
    var shelfHeight: CGFloat
    static let maxSongs = 15

    static func make(inner: CGFloat, height: CGFloat, s: CGFloat, queued: Int) -> NPChillaxPlan {
        let gap = 12 * s, header = 30 * s, row = 64 * s + 14 * s
        let columns = max(2, min(5, Int(inner / (230 * s))))
        guard queued > 0 else { return NPChillaxPlan(coverSide: max(100, min(inner * 0.5, 640 * s, height)), columns: columns, rows: 0, limit: 0, shelfHeight: 0) }
        // the cover is at least as tall as the title block and words need (about 300 pt), the rest is the shelf's
        let minCover = max(100, min(300 * s, inner * 0.38))
        let room = height - minCover - gap - header
        let wanted = Int((Double(min(queued, maxSongs)) / Double(columns)).rounded(.up))
        let rows = max(room >= row ? 1 : 0, min(wanted, 3, Int(room / row)))
        let limit = min(maxSongs, min(queued, rows * columns))
        let shelf = rows > 0 ? header + CGFloat(rows) * row - 14 * s : 0
        let cover = max(100, min(inner * 0.5, 640 * s, height - shelf - gap))
        return NPChillaxPlan(coverSide: cover, columns: columns, rows: rows, limit: limit, shelfHeight: shelf)
    }
}
