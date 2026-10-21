import SwiftUI

/// Apple Music-style navigation: search on top, grouped destinations below, settings at the foot.
struct Sidebar: View {
    @EnvironmentObject var m: PlayerModel
    @FocusState private var searchFocused: Bool

    private let sections: [Tab.Section] = [.listen, .library, .classical, .sound, .discover, .system]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField.padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.self) { sec in
                        let items = Tab.allCases.filter { $0.section == sec && $0 != .search }
                        VStack(alignment: .leading, spacing: 1) {
                            if sec != .listen { Text(sec.rawValue).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 3) }
                            ForEach(items) { t in SidebarItem(tab: t) }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .frame(width: 232)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.07)).frame(width: 0.8) }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(m.tab == .search ? Brand.accent : .secondary)
            TextField("Search", text: $m.searchText).textFieldStyle(.plain).font(.system(size: 13.5)).focused($searchFocused)
                .onSubmit { withAnimation(.smooth(duration: 0.3)) { m.tab = .search } }
            if !m.searchText.isEmpty {
                Button { m.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(searchFocused ? 0.14 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(searchFocused ? Brand.accent.opacity(0.7) : .clear, lineWidth: 1.2))
        .animation(.smooth(duration: 0.15), value: searchFocused)
    }
}

struct SidebarItem: View {
    @EnvironmentObject var m: PlayerModel
    let tab: Tab
    @StateObject private var hover = Box(false)

    var body: some View {
        let selected = m.tab == tab
        Button { withAnimation(.smooth(duration: 0.32)) { m.tab = tab } } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon).symbolVariant(selected ? .fill : .none).font(.system(size: 14, weight: .medium)).frame(width: 20)
                    .foregroundStyle(selected ? Brand.accent : Color.secondary)
                Text(tab.rawValue).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if tab == .player, m.isActive { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 14, height: 12) }
            }
            .padding(.horizontal, 12).frame(height: 31).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.13 : (hover.v ? 0.06 : 0))))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(.smooth(duration: 0.15), value: hover.v)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
