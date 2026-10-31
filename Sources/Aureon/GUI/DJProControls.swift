import SwiftUI
import AppKit

/// The Pro console's palette. It is one dark look by design, whatever the app's theme.
enum PC {
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.047)
    static let s1 = Color(red: 0.055, green: 0.071, blue: 0.090)
    static let s2 = Color(red: 0.078, green: 0.102, blue: 0.129)
    static let s3 = Color(red: 0.106, green: 0.137, blue: 0.173)
    static let line = Color(red: 0.141, green: 0.180, blue: 0.224)
    static let ink = Color(red: 0.933, green: 0.949, blue: 0.965)
    static let ink2 = Color(red: 0.549, green: 0.600, blue: 0.659)
    static let ink3 = Color(red: 0.357, green: 0.400, blue: 0.455)
    static let a = Color(red: 0.184, green: 0.831, blue: 0.878)
    static let b = Color(red: 1.0, green: 0.478, blue: 0.271)
    static let gold = Color(red: 0.878, green: 0.722, blue: 0.380)
    static let ok = Color(red: 0.290, green: 0.871, blue: 0.502)
    static let warn = Color(red: 0.980, green: 0.800, blue: 0.082)
    static let red = Color(red: 1.0, green: 0.267, blue: 0.333)
    static let violet = Color(red: 0.753, green: 0.518, blue: 0.988)
    static let blue = Color(red: 0.376, green: 0.647, blue: 0.980)
    static let aux = Color(red: 0.549, green: 0.600, blue: 0.659)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { Typo.mono(size, weight) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Typo.sans(size, weight) }
    static func deck(_ name: String) -> Color { name == "A" ? a : b }
    static let padColors: [Color] = [a, ok, warn, red, violet, blue, b, gold]
}

struct PCLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(PC.mono(9.5)).tracking(1.1).foregroundColor(PC.ink3).lineLimit(1).fixedSize() }
}

/// A fixed-size push button. `on` lights it in `color`.
struct PCKey: View {
    let title: String
    var on = false
    var color: Color = PC.gold
    var width: CGFloat? = nil
    var height: CGFloat = 24
    var enabled = true
    var size: CGFloat = 10.5
    var help: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(PC.mono(size)).tracking(0.5).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: width, height: height).frame(maxWidth: width == nil ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? color : PC.s3))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? color : PC.line, lineWidth: 0.8))
                .foregroundColor(on ? Color.black.opacity(0.85) : PC.ink2)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help ?? title)
    }
}

/// A button that acts while it is held.
struct PCHold: View {
    let title: String
    var color: Color = PC.gold
    var width: CGFloat? = nil
    var height: CGFloat = 24
    var enabled = true
    var help: String?
    let onChange: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Text(title).font(PC.mono(10.5)).tracking(0.5).lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: width, height: height).frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(down ? color : PC.s3))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(down ? color : PC.line, lineWidth: 0.8))
            .foregroundColor(down ? Color.black.opacity(0.85) : PC.ink2).opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if enabled, !down { down = true; onChange(true) } }.onEnded { _ in if down { down = false; onChange(false) } })
            .help(help ?? title)
            .onDisappear { if down { down = false; onChange(false) } }
    }
}

/// A rotary control of fixed size. Drag up or down (hold ⇧ for fine steps), scroll, or double-click to reset. While the pointer is over it, the
/// label under it shows the value instead — in the same place, so nothing moves.
struct PCKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var tint: Color = PC.gold
    var size: CGFloat = 32
    var reset = 0.0
    var kind: KnobKind = .db
    @State private var start: Double?
    @State private var hover = false

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: Double { max(0, min(1, (value - range.lowerBound) / span)) }
    private var zero: Double { max(0, min(1, (reset - range.lowerBound) / span)) }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) / 2 - 3
                func arc(_ a: Double, _ b: Double) -> Path {
                    var p = Path(); p.addArc(center: c, radius: r, startAngle: .degrees(a - 90), endAngle: .degrees(b - 90), clockwise: false); return p
                }
                ctx.stroke(arc(-135, 135), with: .color(PC.s3), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                let a0 = -135 + 270 * min(zero, fraction), a1 = -135 + 270 * max(zero, fraction)
                if a1 - a0 > 0.5 { ctx.stroke(arc(a0, a1), with: .color(tint), style: StrokeStyle(lineWidth: 3.2, lineCap: .round)) }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.68, width: r * 1.36, height: r * 1.36)), with: .color(Color(red: 0.063, green: 0.086, blue: 0.110)))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.68, width: r * 1.36, height: r * 1.36)), with: .color(PC.line), lineWidth: 0.8)
                let ang = (-135 + 270 * fraction - 90) * .pi / 180
                var tick = Path(); tick.move(to: CGPoint(x: c.x + r * 0.2 * cos(ang), y: c.y + r * 0.2 * sin(ang))); tick.addLine(to: CGPoint(x: c.x + r * 0.62 * cos(ang), y: c.y + r * 0.62 * sin(ang)))
                ctx.stroke(tick, with: .color(PC.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: size, height: size)
            Text(hover || start != nil ? kind.text(value, range: range) : label).font(PC.mono(9)).tracking(hover ? 0 : 0.8)
                .foregroundColor(hover || start != nil ? PC.ink : PC.ink3).lineLimit(1).minimumScaleFactor(0.6).frame(width: max(size + 8, 40), height: 11)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { d in
            if start == nil { start = value }
            let travel = NSEvent.modifierFlags.contains(.shift) ? 700.0 : 190.0
            var v = (start ?? value) - Double(d.translation.height) / travel * span
            v = max(range.lowerBound, min(range.upperBound, v))
            if abs(v - reset) < span * 0.015 && reset > range.lowerBound && reset < range.upperBound { v = reset }
            value = v
        }.onEnded { _ in start = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = reset })
        .onHover { hover = $0 }
        .scrollAdjustable(hovering: hover) { n in value = ScrollStep.apply(value: value, notches: n, range: range, perNotch: 0.02); return true }
        .help("\(label): drag, scroll or double-click to reset")
        .accessibilityElement().accessibilityLabel(Text(label)).accessibilityValue(Text(kind.text(value, range: range)))
        .accessibilityAdjustableAction { dir in value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? 1 : -1) * span * 0.02)) }
    }
}

/// A vertical fader with a metal cap. Drag, scroll, or double-click to return to `reset`.
struct PCFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 110
    var width: CGFloat = 22
    var tint: Color = PC.gold
    var reset = 0.0
    var step = 0.001
    var enabled = true
    var centerMark = false
    @State private var hover = false
    @State private var drag = false

    var body: some View {
        let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let cap: CGFloat = 26
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(PC.line, lineWidth: 0.8))
            Rectangle().fill(PC.s3).frame(width: 2).padding(.vertical, 6)
            if centerMark { Rectangle().fill(tint.opacity(0.8)).frame(height: 1).offset(y: height / 2) }
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                .overlay(Rectangle().fill(tint).frame(height: 2).padding(.horizontal, 3))
                .frame(width: width + 6, height: cap)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .offset(y: (height - cap) * (1 - f))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .gesture(DragGesture(minimumDistance: 0).onChanged { d in
            guard enabled else { return }
            drag = true
            let p = 1 - min(1, max(0, (d.location.y - cap / 2) / (height - cap)))
            let raw = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
            value = max(range.lowerBound, min(range.upperBound, (raw / step).rounded() * step))
        }.onEnded { _ in drag = false })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { value = reset } })
        .onHover { hover = $0 }
        .scrollAdjustable(hovering: hover && enabled) { n in value = ScrollStep.apply(value: value, notches: n, range: range); return true }
        .accessibilityElement().accessibilityValue(Text(String(format: "%.0f percent", (value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100)))
        .accessibilityAdjustableAction { dir in let s = (range.upperBound - range.lowerBound) * 0.02; value = max(range.lowerBound, min(range.upperBound, value + (dir == .increment ? s : -s))) }
    }
}

/// A segmented level meter. It reads its levels itself, at most sixty times a second, so the rest of the window is not redrawn for it.
struct PCMeter: View {
    let read: () -> Float
    var height: CGFloat = 110
    var width: CGFloat = 8
    var segments = 16
    @State private var level: Float = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            Canvas { ctx, size in
                let v = PCMeter.fraction(read())
                let gap: CGFloat = 2, h = (size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
                let lit = Int((v * Float(segments)).rounded(.up))
                for i in 0..<segments {
                    let y = size.height - CGFloat(i + 1) * h - CGFloat(i) * gap
                    let col: Color = i > segments - 3 ? PC.red : i > segments - 6 ? PC.warn : PC.ok
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: 1), with: .color(i < lit ? col : PC.s3))
                }
                _ = tl.date
            }
        }
        .frame(width: width, height: height)
    }

    /// 0…1 across −48…0 dBFS.
    static func fraction(_ v: Float) -> Float { let db = 20 * log10(max(v, 1e-5)); return max(0, min(1, (db + 48) / 48)) }
}

/// The crossfader: a wide rail with a metal cap.
struct PCCrossfader: View {
    @Binding var value: Double          // -1 (A) … +1 (B)
    var height: CGFloat = 26
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            let capW: CGFloat = 40, f = CGFloat((value + 1) / 2)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(PC.line, lineWidth: 0.8))
                Rectangle().fill(PC.s3).frame(height: 2).padding(.horizontal, 8)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.95), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                    .overlay(Rectangle().fill(PC.ink2).frame(width: 2).padding(.vertical, 4))
                    .frame(width: capW, height: height + 4).shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                    .offset(x: (g.size.width - capW) * f)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let p = min(1, max(0, (d.location.x - capW / 2) / max(1, g.size.width - capW)))
                value = Double(p) * 2 - 1
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            .onHover { hover = $0 }
            .scrollAdjustable(hovering: hover) { n in value = ScrollStep.apply(value: value, notches: n, range: -1...1, perNotch: 0.04); return true }
        }
        .frame(height: height)
        .accessibilityElement().accessibilityLabel(Text("Crossfader")).accessibilityValue(Text(value == 0 ? "centre" : String(format: "%+.0f percent", value * 100)))
        .accessibilityAdjustableAction { dir in value = max(-1, min(1, value + (dir == .increment ? 0.05 : -0.05))) }
    }
}

/// A panel with the console's rounded dark look.
struct PCPanel<Content: View>: View {
    var accent: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(DJProMetrics.deckPad)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PC.s1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PC.line, lineWidth: 0.8))
            .overlay(alignment: .top) { if let accent { Rectangle().fill(accent).frame(height: 2).padding(.horizontal, 10).clipShape(Capsule()) } }
    }
}

struct PCCluster<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title { PCLabel(title) }
            content
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PC.s2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PC.line, lineWidth: 0.8))
    }
}

/// Keeps a window at least `size` (content area): the window cannot be dragged below it, and is grown to it when the layout starts.
struct WindowMinimum: NSViewRepresentable {
    let size: CGSize
    func makeNSView(context: Context) -> NSView { MinView(size) }
    func updateNSView(_ v: NSView, context: Context) { (v as? MinView)?.apply(size) }

    final class MinView: NSView {
        private var size: CGSize
        private var previous: NSSize?
        init(_ s: CGSize) { size = s; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func apply(_ s: CGSize) { size = s; update() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
        private func update() {
            guard let w = window else { return }
            if previous == nil { previous = w.contentMinSize }
            w.contentMinSize = NSSize(width: size.width, height: size.height)
            let cur = w.contentRect(forFrameRect: w.frame).size
            if cur.width < size.width || cur.height < size.height, !w.styleMask.contains(.fullScreen) {
                w.setContentSize(NSSize(width: max(cur.width, size.width), height: max(cur.height, size.height)))
            }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let w = window, let p = previous { w.contentMinSize = p }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

/// Reads a deck's cover for the header and the disc label.
@MainActor final class DJCovers: ObservableObject {
    static let shared = DJCovers()
    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []
    func image(for path: String) -> NSImage? {
        if let i = cache[path] { return i }
        guard !pending.contains(path) else { return nil }
        pending.insert(path)
        Task { [weak self] in
            let data = await MetadataEngine.artwork(path: path)
            guard let self else { return }
            if let data, let img = NSImage(data: data) { self.cache[path] = img; self.objectWillChange.send() }
            self.pending.remove(path)
        }
        return nil
    }
}
