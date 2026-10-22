import SwiftUI

/// Navigation in the manner of the system's own sidebars: translucent, grouped, coloured icons, a soft grey selection.
struct Sidebar: View {
    @EnvironmentObject var m: PlayerModel
    @FocusState private var searchFocused: Bool

    private let sections = SidebarLayout.sections

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the window buttons are placed over the left of this row by `WindowChrome`; Back and Forward sit beside them
            HStack(spacing: 0) {
                Color.clear.frame(width: 92, height: 1)
                NavButtons()
                Spacer(minLength: 0)
                AppLogo(size: 24).padding(.trailing, 14).help("Aureon")
            }.frame(height: WindowChrome.band)
            searchField.padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections, id: \.self) { sec in
                        let items = m.sidebar.visible(in: sec)
                        if !items.isEmpty { VStack(alignment: .leading, spacing: 1) {
                            if sec != .listen { Text(sec.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 2).padding(.top, 2) }
                            ForEach(items) { t in SidebarItem(tab: t) }
                        } }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            VStack(spacing: 2) {
                OutputSwitcher()
                DJSwitch()
                HStack(spacing: 6) {
                    SidebarItem(tab: .settings)
                    AppearanceToggle()
                }
            }.padding(.horizontal, 8).padding(.bottom, 10).padding(.top, 4)
        }
        .frame(width: 204)
        .background {
            if ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil || !Theme.current.vibrant { Brand.sidebar } else { VisualEffect(material: .sidebar, blending: .behindWindow) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.current.isLight ? Color.black.opacity(0.12) : Color.black.opacity(0.35)).frame(width: 0.8) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(m.tab == .search ? Brand.accent : .secondary)
            TextField("Search", text: $m.searchText).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onSubmit { withAnimation(.easeOut(duration: 0.16)) { m.tab = .search } }
            if !m.searchText.isEmpty {
                Button { m.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink.opacity(searchFocused ? 0.14 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? Brand.accent.opacity(0.8) : .clear, lineWidth: 1.2))
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }
}

struct SidebarItem: View {
    @EnvironmentObject var m: PlayerModel
    let tab: Tab
    @StateObject private var hover = Box(false)

    var body: some View {
        let selected = m.tab == tab
        Button { withAnimation(.easeOut(duration: 0.14)) { m.djMode = false; m.tab = tab } } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon).symbolVariant(selected ? .fill : .none).font(.system(size: 14, weight: .regular)).frame(width: 20)
                    .foregroundStyle(Brand.accent)
                Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if tab == .player, m.isActive { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 12, height: 10) }
                if tab == .radio, m.current?.isStream == true { Circle().fill(Brand.accent).frame(width: 6, height: 6).shadow(color: Brand.accent, radius: 3) }
            }
            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.ink.opacity(selected ? 0.13 : (hover.v ? 0.06 : 0))))
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .contextMenu {
            if tab != .settings {
                Button("Hide from sidebar") { m.sidebar.setHidden(tab, true); if m.tab == tab { m.tab = .settings; m.settingsSection = .sidebar } }
            }
            Button("Customize sidebar…") { m.djMode = false; m.settingsPage = nil; m.settingsSection = .sidebar; m.tab = .settings }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
