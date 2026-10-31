import SwiftUI

// Popovers that live inside the window. A system popover is placed by the screen, not by the window: next to a button near the window's edge it hangs out over
// the desktop. These are cards drawn in a layer over the window, placed by the side of the button that opened them and kept wholly inside the window (they
// flip to the other side when there is no room, and shrink when the window is small). One is open at a time; a click anywhere else closes it.

/// The popover that is open, and where it ended up.
@MainActor
final class WindowPopovers: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID
        var anchor: CGRect
        var edge: Edge
        var content: AnyView
        var dismiss: () -> Void
    }
    @Published private(set) var entry: Entry?
    /// Where the open card is, in the window's own coordinates (for tests and for keeping it in place).
    @Published var shownFrame: CGRect = .zero
    var isOpen: Bool { entry != nil }

    func present(_ e: Entry) {
        if let old = entry, old.id != e.id { old.dismiss() }
        entry = e
    }
    func move(_ id: UUID, anchor: CGRect) { if entry?.id == id { entry?.anchor = anchor } }
    func close(_ id: UUID) { if entry?.id == id { entry = nil; shownFrame = .zero } }
    /// A click outside the card, or Escape.
    func dismiss() { let e = entry; entry = nil; shownFrame = .zero; e?.dismiss() }

    static let space = "pulse.window"

    /// The card's frame for its size: on the preferred side of the anchor, flipped when it does not fit there, and clamped into the window.
    static func place(size: CGSize, anchor: CGRect, edge: Edge, in window: CGSize, margin: CGFloat = 8, gap: CGFloat = 8) -> CGRect {
        let w = min(size.width, max(0, window.width - 2 * margin)), h = min(size.height, max(0, window.height - 2 * margin))
        var x: CGFloat, y: CGFloat
        switch edge {
        case .bottom, .top:
            var below = edge == .bottom
            let fitsBelow = anchor.maxY + gap + h <= window.height - margin, fitsAbove = anchor.minY - gap - h >= margin
            if below && !fitsBelow && fitsAbove { below = false } else if !below && !fitsAbove && fitsBelow { below = true }
            y = below ? anchor.maxY + gap : anchor.minY - gap - h
            x = anchor.midX - w / 2
        case .leading, .trailing:
            var right = edge == .trailing
            let fitsRight = anchor.maxX + gap + w <= window.width - margin, fitsLeft = anchor.minX - gap - w >= margin
            if right && !fitsRight && fitsLeft { right = false } else if !right && !fitsLeft && fitsRight { right = true }
            x = right ? anchor.maxX + gap : anchor.minX - gap - w
            y = anchor.midY - h / 2
        }
        x = min(max(x, margin), max(margin, window.width - w - margin))
        y = min(max(y, margin), max(margin, window.height - h - margin))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private struct WindowPopoversKey: EnvironmentKey { static let defaultValue: WindowPopovers? = nil }
extension EnvironmentValues {
    var windowPopovers: WindowPopovers? {
        get { self[WindowPopoversKey.self] }
        set { self[WindowPopoversKey.self] = newValue }
    }
}

/// The layer over the window that draws the open popover. Placed over the whole window, in the window's coordinate space.
struct WindowPopoverLayer: View {
    @ObservedObject var center: WindowPopovers

    var body: some View {
        GeometryReader { g in
            if let e = center.entry {
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { center.dismiss() }
                    WindowPopoverCard(entry: e, window: g.size, center: center).id(e.id)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(center.entry != nil)
    }
}

/// One open popover: its content at its own size (scrolling inside the window when the window is too small for it), on a card.
private struct WindowPopoverCard: View {
    let entry: WindowPopovers.Entry
    let window: CGSize
    let center: WindowPopovers
    /// The content's own size, once it has been laid out (the card is not shown before).
    @State private var natural: CGSize?

    var body: some View {
        let limit = CGSize(width: max(0, window.width - 16), height: max(0, window.height - 16))
        let size = CGSize(width: min(natural?.width ?? 320, limit.width), height: min(natural?.height ?? 240, limit.height))
        let frame = WindowPopovers.place(size: size, anchor: entry.anchor, edge: entry.edge, in: window)
        let shape = RoundedRectangle(cornerRadius: Metrics.radius(14), style: .continuous)
        ScrollView(.vertical, showsIndicators: false) {
            entry.content.fixedSize().onGeometryChange(for: CGSize.self, of: { $0.size }) { natural = $0 }
        }
        .scrollBounceBasedOnSize()
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(shape.fill(Brand.canvas))
        .overlay(shape.strokeBorder(Brand.rule, lineWidth: Metrics.hairline))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        .opacity(natural == nil ? 0 : 1)
        .offset(x: frame.minX, y: frame.minY)
        .onChangeCompat(of: frame) { _, f in if natural != nil { center.shownFrame = f } }
        .onChangeCompat(of: natural == nil) { _, waiting in if !waiting { center.shownFrame = frame } }
        .transition(.opacity)
    }
}

private struct WindowPopoverModifier<PopContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let edge: Edge
    let popContent: () -> PopContent
    @Environment(\.windowPopovers) private var center
    @State private var id = UUID()
    @State private var anchor: CGRect = .zero

    func body(content: Content) -> some View {
        if let center {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(WindowPopovers.space)) }) { f in
                    anchor = f
                    if isPresented { center.move(id, anchor: f) }
                }
                .onChangeCompat(of: isPresented) { _, now in if now { present(center) } else { center.close(id) } }
                .onAppear { if isPresented { present(center) } }
                .onDisappear { center.close(id); if isPresented { isPresented = false } }      // a chip rebuilt while open must not leave its owner believing it is still open
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: edge) { popContent() }
        }
    }

    private func present(_ center: WindowPopovers) {
        let binding = $isPresented
        center.present(.init(id: id, anchor: anchor, edge: edge, content: AnyView(popContent()), dismiss: { binding.wrappedValue = false }))
    }
}

extension View {
    /// A popover drawn inside the window (see `WindowPopovers`): `edge` is the side of this view it opens on.
    func windowPopover<C: View>(isPresented: Binding<Bool>, edge: Edge = .bottom, @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(WindowPopoverModifier(isPresented: isPresented, edge: edge, popContent: content))
    }
}
