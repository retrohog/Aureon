import SwiftUI

/// The sidebar's pieces. The sidebar itself is gone (the top rail replaced it), but its layout settings and rows are still what the settings page edits.

/// The typographic scale of the sidebar, in one place.
enum SidebarType {
    static let heading = Typo.sans(10, .regular)
    static func item(selected: Bool) -> Font { Typo.sans(13, selected ? .medium : .regular) }
    static func icon(selected: Bool) -> Font { Typo.sans(13, .light) }
}

/// A group heading: small, upper-case, widely tracked, in the tertiary ink, so the items lead.
struct SidebarHeading: View {
    let text: String
    var body: some View {
        Text(text).font(SidebarType.heading).tracking(Typo.microTracking).textCase(.uppercase).foregroundStyle(Brand.inkTertiary)
            .padding(.horizontal, 16).padding(.top, 0).padding(.bottom, 8)
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

/// The mark of the selected row: a champagne line at the panel's edge, over a faint lift of the row.
struct SidebarSelectionHighlight: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Brand.ink.opacity(0.05))
            Rectangle().fill(Brand.gradientVertical).frame(width: 2)
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
        Button { withAnimation(Motion.glide) { m.djMode = false; m.tab = tab } } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.icon).symbolRenderingMode(.monochrome)
                    .font(SidebarType.icon(selected: selected)).frame(width: 20)
                    .foregroundStyle(selected ? Brand.accentText : Brand.inkSecondary)
                Text(tab.rawValue).font(SidebarType.item(selected: selected)).tracking(Typo.bodyTracking)
                    .foregroundStyle(selected ? Brand.ink : Brand.inkSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if tab == .player, m.isActive { EqualizerBars(active: m.status.state == .playing, color: Brand.accent).frame(width: 12, height: 10) }
                if tab == .radio, m.current?.isStream == true { Rectangle().fill(Brand.accent).frame(width: 4, height: 4) }
            }
            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            .background {
                if selected {
                    if let selectionSpace { SidebarSelectionHighlight().matchedGeometryEffect(id: "sidebar.selection", in: selectionSpace) } else { SidebarSelectionHighlight() }
                } else if hover.v {
                    Rectangle().fill(Brand.ink.opacity(0.04))
                }
            }
            .animation(Motion.touch, value: hover.v)
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
