import SwiftUI

/// Apple Music-style navigation: search on top, grouped destinations below, settings at the foot.
struct Sidebar: View {
    @EnvironmentObject var m: PlayerModel
    @FocusState private var searchFocused: Bool

    private let sections: [Tab.Section] = [.listen, .library, .classical, .sound, .discover, .system]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField.padding(.horizontal, 10).padding(.top, 40).padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.self) { sec in
                        let items = Tab.allCases.filter { $0.section == sec && $0 != .search }
                        VStack(alignment: .leading, spacing: 1) {
                            if sec != .listen { Text(sec.rawValue).microLabel().foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.bottom, 3).padding(.top, 2) }
                            ForEach(items) { t in SidebarItem(tab: t) }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .frame(width: 208)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.3)))
        .panel(radius: 20, fill: 0.02)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(m.tab == .search ? Brand.cyan : .secondary)
            TextField("Search library", text: $m.searchText).textFieldStyle(.plain).font(.system(size: 12.5)).focused($searchFocused)
                .onSubmit { withAnimation(.smooth(duration: 0.3)) { m.tab = .search } }
            if !m.searchText.isEmpty {
                Button { m.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(searchFocused ? 0.12 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(searchFocused ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.white.opacity(0.06)), lineWidth: searchFocused ? 1.2 : 0.8))
        .animation(.smooth(duration: 0.15), value: searchFocused)
    }
}

struct SidebarItem: View {
    @EnvironmentObject var m: PlayerModel
    let tab: Tab
    @StateObject private var hover = Box(false)

    var body: some View {
        let selected = m.tab == tab
        Button { withAnimation(.easeOut(duration: 0.16)) { m.tab = tab } } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon).symbolVariant(selected ? .fill : .none).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.gradientDiagonal) : AnyShapeStyle(Color.secondary))
                Text(tab.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if tab == .player, m.isActive { EqualizerBars(active: m.status.state == .playing, color: Brand.cyan).frame(width: 12, height: 10) }
                if tab == .radio, m.current?.isStream == true { Circle().fill(Brand.pink).frame(width: 6, height: 6).shadow(color: Brand.pink, radius: 4) }
            }
            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan.opacity(0.16), Brand.violet.opacity(0.14), Brand.pink.opacity(0.08)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(hover.v ? 0.06 : 0))))
            .overlay(alignment: .leading) { if selected { Capsule().fill(Brand.gradient).frame(width: 2.5, height: 14).offset(x: -1) } }
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.v)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
