// Draws an app icon: an SF Symbol on a gradient squircle, at 1024px.
// Usage: swift make-icon.swift out.png [symbol] [topHex] [bottomHex]
import AppKit

let args = CommandLine.arguments
let out = args[1]
let symbolName = args.count > 2 ? args[2] : "envelope.open.fill"
func color(_ hex: String) -> NSColor {
    let v = Int(hex, radix: 16) ?? 0x3880FF
    return NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let top = color(args.count > 3 ? args[3] : "388CFF")
let bottom = color(args.count > 4 ? args[4] : "1A4DD9")

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(colors: [top, bottom])!.draw(in: squircle, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium).applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
