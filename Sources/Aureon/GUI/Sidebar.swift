import SwiftUI

/// Navigation in the manner of the system's own sidebars: the translucent sidebar material in every theme, SF Pro in a clear hierarchy
/// (quiet semibold group headings, regular items, the selected item semibold) and a vibrant selection that glides from row to row.
struct Sidebar: View {
    @EnvironmentObject var m: PlayerModel
    @FocusState private var searchFocused: Bool
    @Environment(\.controlActiveState) private var activeState
    /// Like the system's focus ring: shown only while this window is the key window.
    private var searchRing: Bool { searchFocused && activeState == .key }
    @Namespace private var selection

    private let sections = SidebarLayout.sections
    private let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil

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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.self) { sec in
                        let items = m.sidebar.visible(in: sec)
                        if !items.isEmpty { VStack(alignment: .leading, spacing: 1) {
                            if sec != .listen { SidebarHeading(text: sec.rawValue) }
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
        .environment(\.sidebarSelection, selection)
        .frame(width: 204)
        .background {
            if snapshot { Brand.sidebar } else {
                ZStack {
                    VisualEffect(material: .sidebar, blending: .behindWindow)
                    // themes with their own sidebar colour lay it over the material as a tint, so the desktop still glows through
                    if !Theme.current.vibrant { Brand.sidebar.opacity(Theme.current.isLight ? 0.55 : 0.62) }
                }
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.current.isLight ? Color.black.opacity(0.1) : Color.black.opacity(0.35)).frame(width: 0.8) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(m.tab == .search ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
            TextField("Search", text: $m.searchText).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onSubmit { withAnimation(.easeOut(duration: 0.16)) { m.tab = .search } }
            if !m.searchText.isEmpty {
                Button { m.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(searchRing ? 1 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchRing ? Brand.accent.opacity(0.8) : .clear, lineWidth: 1.2))
        .animation(.easeOut(duration: 0.12), value: searchRing)
    }
}

/// The typographic scale of the sidebar, in one place.
enum SidebarType {
    static let heading = Font.system(size: 11, weight: .semibold)
    static func item(selected: Bool) -> Font { .system(size: 13, weight: selected ? .semibold : .regular) }
    static func icon(selected: Bool) -> Font { .system(size: 14, weight: selected ? .semibold : .regular) }
}

/// A group heading: small, semibold, in the tertiary label colour so the items lead.
struct SidebarHeading: View {
    let text: String
    var body: some View {
        Text(text).font(SidebarType.heading).tracking(0.2).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SidebarSelectionKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var sidebarSelection: Namespace.ID? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

/// The selected row's highlight: the system's selection material, so it takes on the vibrancy of the sidebar beneath it like Finder's and Music's.
struct SidebarSelectionHighlight: View {
    private let snapshot = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] != nil
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if snapshot {
            shape.fill(Brand.ink.opacity(0.13))
        } else {
            VisualEffect(material: .selection, blending: .behindWindow, emphasized: false)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(Theme.current.isLight ? 0.35 : 0.06), lineWidth: 0.5))
        }
    }
}

struct SidebarItem: View {
    @EnvironmentObject var m: PlayerModel
    let tab: Tab
    @StateObject private var hover = Box(false)
    @Environment(\.sidebarSelection) private var selectionSpace

    var body: some View {
        let selected = m.tab == tab
        Button { withAnimation(.snappy(duration: 0.22)) { m.djMode = false; m.tab = tab } } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon).symbolVariant(selected ? .fill : .none).symbolRenderingMode(.hierarchical)
                    .font(SidebarType.icon(selected: selected)).frame(width: 20)
                    .foregroundStyle(Brand.accent)
                Text(tab.rawValue).font(SidebarType.item(selected: selected)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
                if tab == .player, m.isActive { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 12, height: 10) }
                if tab == .radio, m.current?.isStream == true { Circle().fill(Brand.accent).frame(width: 6, height: 6).shadow(color: Brand.accent, radius: 3) }
            }
            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            .background {
                if selected {
                    if let selectionSpace { SidebarSelectionHighlight().matchedGeometryEffect(id: "sidebar.selection", in: selectionSpace) } else { SidebarSelectionHighlight() }
                } else if hover.v {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6))
                }
            }
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
