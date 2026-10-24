import SwiftUI

// Settings → Now Playing: which layout, whether the lyrics show and how large, what else is on the screen. The thumbnails are drawn shapes, never live
// views, so nothing runs here but the page itself.

/// A small drawing of a layout (about 160 × 100), in the theme's colours.
struct NPLayoutThumb: View {
    let layout: NowPlayingLayout
    var lyrics = true

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.panel)
                shapes(w, h)
                // the bar under every layout: a seek line and the transport
                bar(w, h)
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
    }

    private func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 3, _ fill: Color = Brand.ink.opacity(0.22)) -> some View {
        RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill).frame(width: w, height: h).offset(x: x, y: y)
    }

    private func bar(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            block(w * 0.06, h * 0.80, w * 0.88, 2, 1, Brand.ink.opacity(0.28))
            block(w * 0.06, h * 0.80, w * 0.3, 2, 1, Brand.accent)
            Circle().fill(Brand.accent).frame(width: h * 0.1, height: h * 0.1).offset(x: w * 0.5 - h * 0.05, y: h * 0.86)
        }
    }

    private func lines(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, centered: Bool, _ n: Int = 4) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<n, id: \.self) { i in
                let bw = w * [0.62, 0.86, 0.7, 0.5][i % 4]
                block(centered ? x + (w - bw) / 2 : x, y + CGFloat(i) * h, bw, h * 0.5, 2, i == 2 ? Brand.ink.opacity(0.9) : Brand.ink.opacity(0.28))
            }
        }
    }

    @ViewBuilder private func shapes(_ w: CGFloat, _ h: CGFloat) -> some View {
        switch layout {
        case .stage:
            if lyrics {
                lines(w * 0.2, h * 0.14, w * 0.6, h * 0.14, centered: true, 4)
                block(w * 0.06, h * 0.9 - h * 0.0, h * 0.08, h * 0.08, 2)
            } else {
                block(w * 0.06, h * 0.12, w * 0.2, h * 0.08, 2); block(w * 0.06, h * 0.26, w * 0.2, h * 0.06, 2)
                block(w * 0.35, h * 0.1, w * 0.3, w * 0.3, 5, Brand.ink.opacity(0.3)); block(w * 0.74, h * 0.12, w * 0.2, h * 0.08, 2); block(w * 0.74, h * 0.26, w * 0.2, h * 0.06, 2)
            }
        case .classic:
            block(w * 0.06, h * 0.1, h * 0.56, h * 0.56, 5, Brand.ink.opacity(0.3))
            block(w * 0.47, h * 0.12, w * 0.38, h * 0.1, 2, Brand.ink.opacity(0.8))
            if lyrics { lines(w * 0.47, h * 0.32, w * 0.46, h * 0.1, centered: false, 4) }
            else { block(w * 0.47, h * 0.32, w * 0.4, h * 0.06, 2); block(w * 0.47, h * 0.44, w * 0.46, h * 0.1, 3); block(w * 0.47, h * 0.58, w * 0.46, h * 0.1, 3) }
        case .fullBleed:
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LinearGradient(colors: [Brand.accent.opacity(0.35), Brand.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            block(w * 0.06, lyrics ? h * 0.1 : h * 0.42, w * (lyrics ? 0.4 : 0.62), lyrics ? h * 0.1 : h * 0.18, 3, Brand.ink.opacity(0.85))
            if lyrics { lines(w * 0.06, h * 0.34, w * 0.5, h * 0.1, centered: false, 3) }
        case .carousel:
            ZStack(alignment: .topLeading) {
                block(w * 0.14, h * 0.14, h * 0.2, h * 0.2, 3); block(w * 0.28, h * 0.1, h * 0.28, h * 0.28, 4)
                block(w * 0.5 - h * 0.17, h * 0.06, h * 0.34, h * 0.34, 5, Brand.ink.opacity(0.4))
                block(w * 0.58, h * 0.1, h * 0.28, h * 0.28, 4); block(w * 0.76, h * 0.14, h * 0.2, h * 0.2, 3)
            }
            block(w * 0.38, h * 0.46, w * 0.24, h * 0.07, 2, Brand.ink.opacity(0.8))
            if lyrics { lines(w * 0.25, h * 0.58, w * 0.5, h * 0.06, centered: true, 3) }
        case .lumen:
            block(w * 0.05, h * 0.08, h * 0.5, h * 0.5, 14, Brand.ink.opacity(0.3)); block(w * 0.05, h * 0.62, w * 0.28, h * 0.06, 2, Brand.ink.opacity(0.8))
            if lyrics { lines(w * 0.4, h * 0.14, w * 0.3, h * 0.1, centered: false, 4) } else { block(w * 0.4, h * 0.14, w * 0.3, h * 0.2, 3); block(w * 0.4, h * 0.4, w * 0.3, h * 0.2, 3) }
            ForEach(0..<4, id: \.self) { i in block(w * 0.76, h * 0.12 + CGFloat(i) * h * 0.14, w * 0.19, h * 0.1, 3) }
            block(w * 0.04, h * 0.76, w * 0.92, h * 0.2, 9, Brand.panel2)
        case .chillax:
            block(w * 0.05, h * 0.08, h * 0.54, h * 0.54, 10, Brand.ink.opacity(0.3))
            block(w * 0.44, h * 0.1, w * 0.46, h * 0.14, 3, Brand.ink.opacity(0.85))
            if lyrics { lines(w * 0.44, h * 0.32, w * 0.46, h * 0.07, centered: false, 4) } else { block(w * 0.44, h * 0.32, w * 0.46, h * 0.06, 2); block(w * 0.44, h * 0.44, w * 0.3, h * 0.06, 2) }
            ForEach(0..<5, id: \.self) { i in block(w * 0.05 + CGFloat(i) * w * 0.186, h * 0.66, w * 0.17, h * 0.1, 3, Brand.ink.opacity(0.16)) }
        }
    }
}

struct NowPlayingSettings: View {
    @EnvironmentObject var m: PlayerModel
    @State private var previewLyrics = true

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Layout", subtitle: "How Now Playing is arranged. The choice is remembered") {
                HStack(spacing: 12) {
                    Text("Preview").font(Typo.sans(13, .medium))
                    SegmentedChoice(selection: $previewLyrics, items: [true, false], label: { $0 ? "Lyrics on" : "Lyrics off" }).frame(width: 220)
                    Text("The pictures below are drawings; nothing plays here.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], alignment: .leading, spacing: 18) {
                    ForEach(NowPlayingLayout.allCases) { l in picker(l) }
                }
                Text(NowPlayingLayout.resolve(m.look.nowPlayingLayout).blurb).font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
            }
            Card(title: "Lyrics", subtitle: "Synced lines from the file's tags or .lrc files next to it") {
                toggleRow("Show lyrics when available", "When there are none, the space shows the credits and the queue.", $m.look.showLyrics)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lyrics size").font(Typo.sans(13, .medium))
                    HStack(spacing: 16) {
                        SegmentedChoice(selection: $m.look.lyricSize, items: LyricSize.allCases, label: { $0.title }).frame(width: 280)
                        Text("Large is the default.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                    }
                }
                LyricsTimingRow()
                LyricsSettingsToggle()
            }
            Card(title: "On this screen", subtitle: "What else Now Playing shows") {
                toggleRow("Add to playlist button", "Next to the heart.", $m.look.showPlaylistButton)
                toggleRow("Credits under the artist", "Written by, produced by and the rest, when the file names them.", $m.look.showCredits)
                toggleRow("Signal path and format tags", "The file, what is done to it, and what the output receives.", $m.look.showSignalTags)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Seek bar").font(Typo.sans(13, .medium))
                    HStack(spacing: 16) {
                        SegmentedChoice(selection: $m.look.seekChoice, items: SeekChoice.allCases, label: { $0.title }).frame(width: 360)
                        Text(m.look.seekChoice == .layout ? "Each layout keeps its own." : "One for every layout.").font(Typo.caption).foregroundStyle(Brand.inkSecondary)
                    }
                }
            }
        }
    }

    private func picker(_ l: NowPlayingLayout) -> some View {
        let on = NowPlayingLayout.resolve(m.look.nowPlayingLayout) == l
        return Button { withAnimation(Motion.touch) { m.look.nowPlayingLayout = l.rawValue } } label: {
            VStack(alignment: .leading, spacing: 6) {
                NPLayoutThumb(layout: l, lyrics: previewLyrics)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Brand.accentText : Brand.rule, lineWidth: on ? 2 : Metrics.hairline))
                HStack(spacing: 4) {
                    Text(l.title).font(Typo.sans(13.5, on ? .medium : .regular))
                    if l == .stage { Text("default").font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary) }
                    if on { Image(systemName: "checkmark").font(Typo.sans(10, .medium)).foregroundStyle(Brand.accentText) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(l.title).accessibilityHint(l.blurb).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggleRow(_ title: String, _ hint: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.sans(14))
                Text(hint).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: value).accessibilityLabel(title).fixedSize()
        }
    }
}
