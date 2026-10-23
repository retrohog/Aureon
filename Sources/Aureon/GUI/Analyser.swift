import SwiftUI
import AppKit

// The analyser: the spectrum, the spectrogram and the levels (VU dials and peak bars) together in one view that fills the space it is given. Narrow
// (the side panel) they are three full-width rows; wide, the spectrum and the spectrogram sit side by side over the levels. Titles are small tracked
// capitals, axis labels SF Mono, gridlines hairlines, and the live trace is champagne gold. One display-linked loop, capped at 60 frames a second,
// drives all three, and stops while the window cannot be seen. Nothing here touches the audio thread: it reads what the analysis thread publishes.

enum AnalyserSection: String, CaseIterable, Identifiable {
    case spectrum, spectrogram, levels
    var id: String { rawValue }
    var title: String { switch self { case .spectrum: "Spectrum"; case .spectrogram: "Spectrogram"; case .levels: "Levels" } }
}

/// How the three graphs are arranged for a width, and how tall each is for a height so that together they fill it. Pure, so it is testable.
enum AnalyserLayout {
    enum Arrangement: Equatable { case stacked, grid }
    static let gridMinimumWidth: CGFloat = 640
    static let spacing: CGFloat = 20
    static let titleHeight: CGFloat = 16

    static func arrangement(width: CGFloat) -> Arrangement { width >= gridMinimumWidth ? .grid : .stacked }

    /// The rows of graphs: every section appears once.
    static func rows(_ a: Arrangement) -> [[AnalyserSection]] { a == .grid ? [[.spectrum, .spectrogram], [.levels]] : [[.spectrum], [.spectrogram], [.levels]] }

    /// The height of each graph (below its title). `rows` stack with `spacing` between them; the graphs share what is left in proportion.
    static func heights(available: CGFloat, _ a: Arrangement) -> [AnalyserSection: CGFloat] {
        let rowCount = CGFloat(rows(a).count)
        let free = max(0, available - spacing * (rowCount - 1) - titleHeight * rowCount)
        switch a {
        case .stacked:
            let levels = max(96, free * 0.34), rest = free - levels
            return [.spectrum: rest / 2, .spectrogram: rest / 2, .levels: levels]
        case .grid:
            let top = free * 0.7
            return [.spectrum: top, .spectrogram: top, .levels: free - top]
        }
    }
}

struct AnalyserView: View {
    @EnvironmentObject var m: PlayerModel
    let size: CGSize
    @StateObject private var visible = Box(true)

    var body: some View {
        if m.visualizerEnabled {
            let a = AnalyserLayout.arrangement(width: size.width)
            let h = AnalyserLayout.heights(available: size.height, a)
            TimelineView(.animation(minimumInterval: UIRate.analyserInterval, paused: !visible.v)) { _ in
                let snap = m.player.analysis.snapshot()
                VStack(alignment: .leading, spacing: AnalyserLayout.spacing) {
                    if a == .grid {
                        HStack(alignment: .top, spacing: AnalyserLayout.spacing) {
                            section(.spectrum, height: h[.spectrum] ?? 0) { SpectrumCanvas(analysis: m.player.analysis) }
                            section(.spectrogram, height: h[.spectrogram] ?? 0) { SpectrogramCanvas(analysis: m.player.analysis) }
                        }
                        section(.levels, height: h[.levels] ?? 0) { levels(snap.meters, height: h[.levels] ?? 0, wide: true) }
                    } else {
                        section(.spectrum, height: h[.spectrum] ?? 0) { SpectrumCanvas(analysis: m.player.analysis) }
                        section(.spectrogram, height: h[.spectrogram] ?? 0) { SpectrogramCanvas(analysis: m.player.analysis) }
                        section(.levels, height: h[.levels] ?? 0) { levels(snap.meters, height: h[.levels] ?? 0, wide: false) }
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
                visible.v = (n.object as? NSWindow)?.occlusionState.contains(.visible) ?? true
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Analyser: spectrum, spectrogram and levels")
        } else {
            Text("The analyser is off. Turn it on in Atelier → Sound → Visualiser.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary).padding(.vertical, 16)
        }
    }

    private func section<Content: View>(_ s: AnalyserSection, height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.title).font(Typo.sans(9, .regular)).tracking(Typo.microTracking).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
                .frame(height: AnalyserLayout.titleHeight, alignment: .topLeading)
            content().frame(maxWidth: .infinity).frame(height: height).plotInset()
        }
    }

    /// The two VU dials and the peak bars, filling the height they are given.
    @ViewBuilder private func levels(_ meters: MeterSnapshot, height: CGFloat, wide: Bool) -> some View {
        if wide {
            HStack(spacing: 16) {
                VUMeterView(value: meters.vuL, label: "L").aspectRatio(1.55, contentMode: .fit)
                VUMeterView(value: meters.vuR, label: "R").aspectRatio(1.55, contentMode: .fit)
                PeakBars(meters: meters).frame(maxWidth: .infinity).frame(minWidth: 220, minHeight: 56, maxHeight: 56)
            }
            .frame(height: height)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    VUMeterView(value: meters.vuL, label: "L")
                    VUMeterView(value: meters.vuR, label: "R")
                }
                .frame(height: max(64, height - 8 - 56))
                PeakBars(meters: meters).frame(height: 56)
            }
        }
    }
}

/// The side panel's page: a header, then the three graphs filling the rest.
struct AnalyserPanelPage: View {
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Analyser").kicker().foregroundStyle(Brand.inkSecondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Close").accessibilityLabel("Close Analyser")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            GeometryReader { g in AnalyserView(size: CGSize(width: max(0, g.size.width - 32), height: max(0, g.size.height - 24))).padding(.horizontal, 16).padding(.bottom, 8) }
        }
    }
}
