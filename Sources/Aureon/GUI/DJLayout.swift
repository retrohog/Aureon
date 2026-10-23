import SwiftUI

/// Which parts of the DJ console are shown and in what order. Every area of the console is a list of sections; the person can hide, show and
/// reorder them (the "Layout" button in the console's header). Saved between runs.
struct DJLayout: Codable, Equatable {
    enum Area: String, CaseIterable, Codable {
        case deck = "Each deck", strip = "Each mixer channel", bottom = "Bottom bar", page = "Page"
    }
    struct Item: Equatable { let id: String; let title: String; let icon: String }

    var hidden: Set<String> = []
    var order: [String] = []

    static let items: [Area: [Item]] = [
        .deck: [Item(id: "cues", title: "Hot cues", icon: "mappin.and.ellipse"), Item(id: "loops", title: "Loops", icon: "repeat"),
                Item(id: "roll", title: "Beat jump and loop roll", icon: "forward.frame"), Item(id: "fx", title: "Effects", icon: "wand.and.stars"),
                Item(id: "tools", title: "Tempo tools, brake, eject", icon: "metronome"), Item(id: "pitch", title: "Pitch fader", icon: "slider.vertical.3")],
        .strip: [Item(id: "trim", title: "Trim (input gain)", icon: "dial.low"), Item(id: "eq", title: "Equalizer: high, mid, low", icon: "slider.horizontal.3"),
                 Item(id: "kill", title: "EQ kill switches", icon: "speaker.slash"), Item(id: "filter", title: "Filter sweep", icon: "waveform.path"),
                 Item(id: "assign", title: "Crossfader assign", icon: "arrow.left.arrow.right"), Item(id: "pfl", title: "Headphone cue", icon: "headphones"),
                 Item(id: "fader", title: "Channel fader and meter", icon: "slider.vertical.3")],
        .bottom: [Item(id: "master", title: "Master EQ and level", icon: "dial.medium"), Item(id: "crossfader", title: "Crossfader", icon: "slider.horizontal.below.rectangle"),
                  Item(id: "automix", title: "Auto mix", icon: "arrow.triangle.swap"), Item(id: "phones", title: "Headphones", icon: "headphones")],
        .page: [Item(id: "masterbar", title: "Master bar", icon: "rectangle.bottomthird.inset.filled"), Item(id: "browser", title: "Track browser", icon: "list.bullet.rectangle")],
    ]

    func items(_ area: Area) -> [Item] {
        let base = Self.items[area] ?? []
        func rank(_ i: Item) -> Int { order.firstIndex(of: "\(area.rawValue)/\(i.id)") ?? (order.count + (base.firstIndex(of: i) ?? 0)) }
        return base.sorted { rank($0) < rank($1) }
    }
    func visible(_ area: Area) -> [String] { items(area).map(\.id).filter { !hidden.contains("\(area.rawValue)/\($0)") } }
    func isShown(_ area: Area, _ id: String) -> Bool { !hidden.contains("\(area.rawValue)/\(id)") }

    mutating func setShown(_ area: Area, _ id: String, _ shown: Bool) {
        let key = "\(area.rawValue)/\(id)"
        if shown { hidden.remove(key) } else { hidden.insert(key) }
    }

    mutating func move(_ area: Area, _ id: String, by delta: Int) {
        var list = items(area).map(\.id)
        guard let i = list.firstIndex(of: id), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        order = order.filter { !$0.hasPrefix(area.rawValue + "/") } + list.map { "\(area.rawValue)/\($0)" }
    }

    static let key = "aureon.dj.layout"
    static func load(_ d: UserDefaults = .standard) -> DJLayout { d.data(forKey: key).flatMap { try? JSONDecoder().decode(DJLayout.self, from: $0) } ?? DJLayout() }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// The editor: sections of each area with an eye to show or hide them and arrows to move them.
struct DJLayoutEditor: View {
    @EnvironmentObject var dj: DJModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Arrange the console").font(Typo.sans(15, .semibold))
                Text("Hide what you do not use, and put the rest in the order you like. It is remembered.").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                ForEach(DJLayout.Area.allCases, id: \.self) { area in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(area.rawValue.uppercased()).font(Typo.sans(10.5, .semibold)).foregroundStyle(Brand.inkSecondary).tracking(0.8)
                        let list = dj.layout.items(area)
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            let shown = dj.layout.isShown(area, item.id)
                            HStack(spacing: 8) {
                                Button { dj.layout.setShown(area, item.id, !shown) } label: { Image(systemName: shown ? "eye" : "eye.slash").frame(width: 22).foregroundStyle(shown ? Brand.accent : .secondary) }.buttonStyle(.plain)
                                Image(systemName: item.icon).frame(width: 18).foregroundStyle(Brand.inkSecondary)
                                Text(item.title).opacity(shown ? 1 : 0.5)
                                Spacer(minLength: 6)
                                Button { dj.layout.move(area, item.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(i == 0)
                                Button { dj.layout.move(area, item.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(i == list.count - 1)
                            }.font(Typo.sans(12.5)).padding(.vertical, 2)
                        }
                    }
                }
                Button("Reset to the default layout") { dj.layout = DJLayout() }.padding(.top, 4)
            }.padding(16)
        }
        .frame(width: 320, height: 520)
    }
}
