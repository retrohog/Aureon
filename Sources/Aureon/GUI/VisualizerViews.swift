import SwiftUI
import AppKit

// 60 fps visualisers. Nothing here touches the audio thread: it reads snapshots that the analysis thread publishes.

enum Heat {
    /// Black → indigo → magenta → orange → yellow → white.
    static let lut: [UInt32] = {
        let stops: [(Double, (Double, Double, Double))] = [(0, (0, 0, 0.02)), (0.22, (0.17, 0.05, 0.40)), (0.45, (0.55, 0.12, 0.42)), (0.68, (0.93, 0.40, 0.18)), (0.88, (0.99, 0.80, 0.25)), (1, (1, 1, 0.9))]
        return (0..<256).map { i in
            let t = Double(i) / 255
            var k = 0; while k < stops.count - 2 && t > stops[k + 1].0 { k += 1 }
            let (t0, a) = stops[k], (t1, b) = stops[k + 1], f = max(0, min(1, (t - t0) / (t1 - t0)))
            func c(_ x: Double, _ y: Double) -> UInt32 { UInt32(max(0, min(255, (x + (y - x) * f) * 255))) }
            return 0xFF00_0000 | (c(a.2, b.2) << 16) | (c(a.1, b.1) << 8) | c(a.0, b.0)      // little-endian RGBA: R in the low byte
        }
    }()

    static func image(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt32](repeating: 0, count: width * height)
        for i in 0..<(width * height) { rgba[i] = lut[Int(pixels[i])] }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// x position (0…1) of a frequency on the 20 Hz – 20 kHz log axis.
func logX(_ hz: Double) -> Double { log(hz / 20) / log(1000) }

struct SpectrumCanvas: View {
    let analysis: AnalysisEngine
    var body: some View {
        Canvas { ctx, size in
            let (bars, _) = analysis.snapshot()
            let columns = 96, per = bars.count / columns
            let w = size.width / CGFloat(columns)
            for g in stride(from: -80, through: -10, by: 10) {                                    // dB grid
                let y = size.height * (1 - CGFloat((Double(g) + 90) / 90))
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Brand.ink.opacity(0.07)), lineWidth: 0.5)
            }
            for c in 0..<columns {
                let v = (0..<per).map { bars[c * per + $0] }.max() ?? -120
                let h = size.height * CGFloat(max(0, min(1, (Double(v) + 90) / 90)))
                let rect = CGRect(x: CGFloat(c) * w + 0.5, y: size.height - h, width: max(1, w - 1), height: h)
                let t = Double(c) / Double(columns)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .linearGradient(Gradient(colors: [Color(hue: 0.60 - 0.55 * t, saturation: 0.8, brightness: 1), Color(hue: 0.60 - 0.55 * t, saturation: 0.9, brightness: 0.55)]),
                                                                                               startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
            for (hz, label) in [(50.0, "50"), (100, "100"), (500, "500"), (1000, "1k"), (5000, "5k"), (10000, "10k"), (20000, "20k")] {
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: size.width * CGFloat(logX(hz)), y: size.height - 6))
            }
        }
    }
}

struct SpectrogramCanvas: View {
    let analysis: AnalysisEngine
    var body: some View {
        Canvas { ctx, size in
            let sg = analysis.spectrogram()
            if let img = Heat.image(pixels: sg.pixels, width: sg.width, height: sg.height) {
                ctx.draw(Image(decorative: img, scale: 1), in: CGRect(origin: .zero, size: size))
            }
            for (hz, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
                let y = size.height * (1 - CGFloat(logX(hz)))
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Brand.ink.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)), at: CGPoint(x: 14, y: y - 6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// An analog VU dial: 0 VU is the reference level, the last 3 dB are the red zone.
struct VUMeterView: View {
    let value: Float            // dB re 0 VU
    let label: String

    static let marks: [(Double, String)] = [(-20, "20"), (-10, "10"), (-7, "7"), (-5, "5"), (-3, "3"), (0, "0"), (3, "+3")]
    static func fraction(_ vu: Double) -> Double { max(0, min(1.05, pow(10, vu / 20) / pow(10, 3.0 / 20))) }

    var body: some View {
        Canvas { ctx, size in
            let face = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: face, cornerRadius: 8), with: .linearGradient(Gradient(colors: [Color(red: 0.96, green: 0.90, blue: 0.72), Color(red: 0.88, green: 0.80, blue: 0.58)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let pivot = CGPoint(x: size.width / 2, y: size.height * 1.12), radius = size.height * 0.98
            func point(_ f: Double, _ r: CGFloat) -> CGPoint {
                let a = Angle.degrees(-50 + 100 * f).radians
                return CGPoint(x: pivot.x + r * CGFloat(sin(a)), y: pivot.y - r * CGFloat(cos(a)))
            }
            let ink = Color(red: 0.16, green: 0.12, blue: 0.08)
            // red zone
            var red = Path()
            for i in 0...20 { let f = VUMeterView.fraction(0) + (VUMeterView.fraction(3) - VUMeterView.fraction(0)) * Double(i) / 20; let p = point(f, radius * 0.86); if i == 0 { red.move(to: p) } else { red.addLine(to: p) } }
            ctx.stroke(red, with: .color(Color(red: 0.8, green: 0.1, blue: 0.1)), lineWidth: 5)
            var arc = Path()
            for i in 0...60 { let p = point(VUMeterView.fraction(-20) + (VUMeterView.fraction(0) - VUMeterView.fraction(-20)) * Double(i) / 60, radius * 0.86); if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) } }
            ctx.stroke(arc, with: .color(ink), lineWidth: 1.2)
            for (vu, text) in VUMeterView.marks {
                let f = VUMeterView.fraction(vu)
                var t = Path(); t.move(to: point(f, radius * 0.86)); t.addLine(to: point(f, radius * 0.80)); ctx.stroke(t, with: .color(vu > 0 ? Color(red: 0.8, green: 0.1, blue: 0.1) : ink), lineWidth: 1.4)
                ctx.draw(Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(vu > 0 ? Color(red: 0.8, green: 0.1, blue: 0.1) : ink), at: point(f, radius * 0.70))
            }
            ctx.draw(Text("VU").font(.system(size: 13, weight: .bold, design: .serif)).foregroundStyle(ink), at: CGPoint(x: size.width / 2, y: size.height * 0.80))
            ctx.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.opacity(0.7)), at: CGPoint(x: 14, y: 12))
            // needle
            let f = VUMeterView.fraction(Double(value))
            var needle = Path(); needle.move(to: point(f, radius * 0.18)); needle.addLine(to: point(f, radius * 0.88))
            ctx.stroke(needle, with: .color(Color(red: 0.1, green: 0.07, blue: 0.05)), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 9, y: pivot.y - 9, width: 18, height: 18)), with: .color(Color(red: 0.12, green: 0.09, blue: 0.07)))
            var clip = Path(); clip.addRoundedRect(in: face, cornerSize: CGSize(width: 8, height: 8))
            ctx.stroke(clip, with: .color(ink.opacity(0.5)), lineWidth: 1)
        }
    }
}

struct PeakBars: View {
    let meters: MeterSnapshot
    var body: some View {
        Canvas { ctx, size in
            func bar(_ y: CGFloat, _ rms: Float, _ peak: Float, _ name: String) {
                let h: CGFloat = 12, w = size.width - 34
                func x(_ db: Float) -> CGFloat { 22 + w * CGFloat(max(0, min(1, (Double(db) + 60) / 60))) }
                ctx.fill(Path(roundedRect: CGRect(x: 22, y: y, width: w, height: h), cornerRadius: 3), with: .color(Brand.ink.opacity(0.08)))
                let fill = CGRect(x: 22, y: y, width: x(rms) - 22, height: h)
                ctx.fill(Path(roundedRect: fill, cornerRadius: 3), with: .linearGradient(Gradient(colors: [.green, .green, .yellow, .red]), startPoint: CGPoint(x: 22, y: 0), endPoint: CGPoint(x: 22 + w, y: 0)))
                var pk = Path(); pk.move(to: CGPoint(x: x(peak), y: y - 1)); pk.addLine(to: CGPoint(x: x(peak), y: y + h + 1))
                ctx.stroke(pk, with: .color(peak > -1 ? .red : .white), lineWidth: 2)
                ctx.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: 9, y: y + h / 2))
            }
            bar(4, meters.rmsL, meters.peakL, "L"); bar(24, meters.rmsR, meters.peakR, "R")
            for db in [-60, -40, -20, -10, -3, 0] {
                let x = 22 + (size.width - 34) * CGFloat(Double(db + 60) / 60)
                ctx.draw(Text("\(db)").font(.system(size: 8)).foregroundStyle(.secondary), at: CGPoint(x: x, y: 46))
            }
            let c = meters.clipped
            ctx.fill(Path(ellipseIn: CGRect(x: size.width - 10, y: 0, width: 8, height: 8)), with: .color(c ? .red : .red.opacity(0.18)))
        }
    }
}

struct VisualizerCard: View {
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        Card(title: "Spectrum & meters", subtitle: "Computed on a separate thread from a copy of the audio: it cannot disturb playback") {
            Toggle("Show visualiser", isOn: $m.visualizerEnabled)
            if m.visualizerEnabled {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    VStack(spacing: 12) {
                        SpectrumCanvas(analysis: m.player.analysis).frame(height: 130)
                        SpectrogramCanvas(analysis: m.player.analysis).frame(height: 150)
                        let snap = m.player.analysis.snapshot()
                        HStack(spacing: 12) {
                            VUMeterView(value: snap.meters.vuL, label: "L").frame(height: 110)
                            VUMeterView(value: snap.meters.vuR, label: "R").frame(height: 110)
                        }
                        PeakBars(meters: snap.meters).frame(height: 56)
                    }
                }
                HStack {
                    Text("0 VU =").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { m.player.analysis.vuReferenceDBFS }, set: { m.player.analysis.vuReferenceDBFS = $0; m.objectWillChange.send() })) {
                        Text("−18 dBFS (EBU)").tag(Float(-18)); Text("−20 dBFS (SMPTE)").tag(Float(-20)); Text("−14 dBFS").tag(Float(-14))
                    }.labelsHidden().fixedSize()
                }
            }
        }
    }
}
