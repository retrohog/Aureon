import SwiftUI

// The queue panel's three tabs: the Queue itself, History (what was played) and Output (where the sound of the song in focus goes).

enum QueueTab: String, CaseIterable, Identifiable {
    case queue = "Queue", history = "History", output = "Output"
    var id: String { rawValue }
}

/// A song that was played, in the order it was heard.
struct PlayedEntry: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var at: Date
}

/// The songs heard since the app opened, newest first, one entry per play (a song restarted straight away is not listed twice).
struct PlayedLog: Equatable {
    static let limit = 200
    private(set) var entries: [PlayedEntry] = []

    mutating func note(path: String, title: String, artist: String, album: String, at: Date = Date()) {
        if entries.first?.path == path { return }
        entries.insert(PlayedEntry(path: path, title: title, artist: artist, album: album, at: at), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
    mutating func clear() { entries = [] }

    /// "just now", "3 min ago", "2 h ago", "yesterday", or the date.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, Int((s / 60).rounded()))) min ago" }
        if s < 86_400 { return "\(Int((s / 3600).rounded())) h ago" }
        if s < 172_800 { return "yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The switch between the three tabs, at the top of the queue panel.
struct QueueTabs: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        SegmentedChoice(selection: $m.queueTab, items: QueueTab.allCases, label: { $0.rawValue }, singleLine: true)
            .padding(.horizontal, 16).padding(.bottom, 10)
    }
}

/// Songs played so far; a click plays the song again.
struct QueueHistory: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        if m.playedLog.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(Typo.sans(34, .light)).foregroundStyle(Brand.inkSecondary)
                Text("Songs you play will be listed here.").font(Typo.callout).foregroundStyle(Brand.inkSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(m.playedLog.entries) { e in row(e) }
                    }.padding(.horizontal, 8)
                }
                Text("Since Aureon opened  ·  click to play again").font(Typo.sans(10.5)).foregroundStyle(Brand.inkTertiary).padding(8)
            }
        }
    }

    private func row(_ e: PlayedEntry) -> some View {
        Button { m.playAgain(path: e.path) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(Typo.sans(13, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text([e.artist, e.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(PlayedLog.age(e.at)).font(Typo.sans(11)).foregroundStyle(Brand.inkTertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(e.title) again")
    }
}

/// Where the sound of the song goes: the output device, its rate, and the steps from the file to the device.
struct QueueOutput: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        let steps = NPSignal.steps(source: m.status.sourceInfo, output: m.status.info, stages: m.status.pipeline, bitPerfect: m.status.bitPerfect, exclusive: m.exclusive, device: m.status.deviceName)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Circle().fill(Brand.accent).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.selectedDevice?.name ?? "No output device").font(Typo.sans(14, .medium)).lineLimit(1)
                        if let rate = m.status.info?.sampleRate, rate > 0, m.isActive { Text(formatRate(rate)).font(Typo.mono(11)).foregroundStyle(Brand.inkSecondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).background(RoundedRectangle(cornerRadius: Metrics.radius(10), style: .continuous).fill(Brand.panel2))
                if steps.isEmpty {
                    Text("Play a song to see where its sound goes.").font(Typo.callout).foregroundStyle(Brand.inkSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { i, st in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    Circle().fill(Brand.accent).frame(width: 8, height: 8).padding(.top, 5)
                                    if i < steps.count - 1 { Rectangle().fill(Brand.ink.opacity(0.18)).frame(width: 1.5).frame(maxHeight: .infinity) }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(st.title).font(Typo.sans(13, .medium))
                                    Text(st.detail).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.bottom, i < steps.count - 1 ? 14 : 0)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button { m.quickPanel = nil; m.showSound(.output) } label: { Label("Output settings", systemImage: "slider.horizontal.3").font(Typo.sans(12.5)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.accentText)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}
