import SwiftUI

/// Which pages the sidebar shows and in what order within each group. Saved, and editable in Settings → Sidebar.
struct SidebarLayout: Codable, Equatable {
    var hidden: Set<String> = []
    /// Preferred order of all pages (raw values); pages not listed keep their default place after the listed ones.
    var order: [String] = []

    static let sections: [Tab.Section] = [.listen, .library, .classical, .discover, .sound, .tools]
    /// Pages that can be moved or hidden. Search lives in the field above the list, Settings is always at the bottom.
    static func editable(in sec: Tab.Section) -> [Tab] { Tab.allCases.filter { $0.section == sec && $0 != .search && $0 != .settings && $0 != .soulseek } }

    func ordered(in sec: Tab.Section) -> [Tab] {
        let base = Self.editable(in: sec)
        func rank(_ t: Tab) -> Int { order.firstIndex(of: t.rawValue) ?? (order.count + (base.firstIndex(of: t) ?? 0)) }
        return base.sorted { rank($0) < rank($1) }
    }
    func visible(in sec: Tab.Section) -> [Tab] { ordered(in: sec).filter { !hidden.contains($0.rawValue) } }
    func isHidden(_ t: Tab) -> Bool { hidden.contains(t.rawValue) }
    var hiddenTabs: [Tab] { Tab.allCases.filter { hidden.contains($0.rawValue) } }

    mutating func setHidden(_ t: Tab, _ h: Bool) {
        guard t != .settings, t != .search else { return }
        if h { hidden.insert(t.rawValue) } else { hidden.remove(t.rawValue) }
    }

    /// Moves a page one step up or down inside its group.
    mutating func move(_ t: Tab, by delta: Int) {
        var list = ordered(in: t.section)
        guard let i = list.firstIndex(of: t), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        // keep the other groups' saved order, replace this group's
        let others = order.filter { r in !Self.editable(in: t.section).contains { $0.rawValue == r } }
        order = others + list.map(\.rawValue)
    }

    static let key = "aureon.sidebar"
    static func load(_ d: UserDefaults = .standard) -> SidebarLayout {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SidebarLayout.self, from: $0) } ?? SidebarLayout()
    }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// The app's logo, as the icon the system shows for it.
struct AppLogo: View {
    var size: CGFloat = 22
    var body: some View {
        // a small hallmark: a serif A in a hairline square, in the accent
        Text("A").font(Typo.serif(size * 0.7, .light)).foregroundStyle(Brand.accentText)
            .frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(Brand.coachline, lineWidth: Metrics.hairline))
            .accessibilityLabel("Aureon")
    }
}

struct SidebarSettings: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Pages", subtitle: "Choose which pages the quiet headers under the rail show up front, and in what order. A page you hide leaves that line; ⌘K still finds every page") {
                ForEach(SidebarLayout.sections, id: \.self) { sec in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sec == .listen ? "Listen" : sec.rawValue).font(Typo.caption.weight(.semibold)).foregroundStyle(Brand.inkSecondary).padding(.top, 8)
                        let list = m.sidebar.ordered(in: sec)
                        ForEach(Array(list.enumerated()), id: \.element) { i, t in
                            HStack(spacing: 12) {
                                Image(systemName: t.icon).frame(width: 20).foregroundStyle(Brand.accent)
                                Text(t.rawValue)
                                Spacer()
                                Button { m.sidebar.move(t, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                                Button { m.sidebar.move(t, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == list.count - 1)
                                Toggle("", isOn: Binding(get: { !m.sidebar.isHidden(t) }, set: { m.sidebar.setHidden(t, !$0) })).labelsHidden().toggleStyle(.rule).controlSize(.small)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("Reset to default") { m.sidebar = SidebarLayout() }
                    Spacer()
                }.padding(.top, 8)
                Note(text: "Settings itself, and the search field, always stay. Right-click any sidebar item to hide it.")
            }
            let hidden = m.sidebar.hiddenTabs
            if !hidden.isEmpty {
                Card(title: "Hidden pages", subtitle: "Pages you took out of the sidebar") {
                    ForEach(hidden) { t in
                        HStack {
                            Image(systemName: t.icon).frame(width: 20).foregroundStyle(Brand.accent)
                            Text(t.rawValue)
                            Spacer()
                            Button("Open") { withAnimation(.easeOut(duration: 0.14)) { m.djMode = false; m.tab = t } }
                            Button("Show in sidebar") { m.sidebar.setHidden(t, false) }
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
