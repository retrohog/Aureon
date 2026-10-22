import AppKit
// Draws the app icon: the artwork in Packaging/AppIcon-source.png on a rounded tile with the standard margin. Usage: make_icon.swift <out.png> <AppIcon-source.png>
let size = 1024
let src = URL(fileURLWithPath: CommandLine.arguments[2])
guard let art = NSImage(contentsOf: src) else { fatalError("missing \(src.path)") }
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 52, dy: 52)
NSGraphicsContext.current?.cgContext.saveGState()
NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.205, yRadius: rect.width * 0.205).addClip()
art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.cgContext.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
