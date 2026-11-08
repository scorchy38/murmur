import AppKit

let size = NSSize(width: 680, height: 420)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: (680 - width) / 2, y: y), withAttributes: attributes)
}
text("Murmur", y: 350, font: .systemFont(ofSize: 34, weight: .semibold), color: .black)
text("Less typing. More thinking.", y: 318, font: .systemFont(ofSize: 16), color: .darkGray)
let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
arrow.withSymbolConfiguration(config)?.draw(in: NSRect(x: 320, y: 180, width: 40, height: 32))
text("Drag Murmur to Applications", y: 62, font: .systemFont(ofSize: 17, weight: .medium), color: .black)
text("Then eject this disk and open Murmur from Applications.", y: 36, font: .systemFont(ofSize: 12), color: .darkGray)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
