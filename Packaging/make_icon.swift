import AppKit
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 60, dy: 60)
let path = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(colors: [NSColor(red: 0.16, green: 0.10, blue: 0.40, alpha: 1), NSColor(red: 0.52, green: 0.20, blue: 0.66, alpha: 1)])!.draw(in: path, angle: -60)
NSColor.white.withAlphaComponent(0.95).setFill()
let heights: [CGFloat] = [0.18, 0.34, 0.55, 0.78, 0.46, 0.66, 0.28, 0.40, 0.14]
let barW: CGFloat = 54, gap: CGFloat = 28
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
for h in heights {
    let bh = h * 520
    NSBezierPath(roundedRect: NSRect(x: x, y: (CGFloat(size) - bh) / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
