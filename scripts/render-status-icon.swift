import AppKit

let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let regex = try NSRegularExpression(pattern: #"\sd="([\s\S]*?)""#)
let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
let commands = (source as NSString).substring(with: match.range(at: 1))
let tokens = try NSRegularExpression(pattern: #"[MCZ]|-?\d+(?:\.\d+)?"#)
    .matches(in: commands, range: NSRange(commands.startIndex..., in: commands))
    .map { (commands as NSString).substring(with: $0.range) }
let path = CGMutablePath()
var index = 0
func point() -> CGPoint {
    defer { index += 2 }
    return CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
}
while index < tokens.count {
    let command = tokens[index]; index += 1
    switch command {
    case "M": path.move(to: point())
    case "C":
        let first = point(), second = point(), end = point()
        path.addCurve(to: end, control1: first, control2: second)
    case "Z": path.closeSubpath()
    default: fatalError("Unsupported contour command")
    }
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for scale in 1...3 {
    let pixels = 18 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.setShouldAntialias(true)
    let factor = CGFloat(17 * scale) / 607
    let marginX = (CGFloat(pixels) - 607 * factor) / 2
    let marginY = (CGFloat(pixels) - 563 * factor) / 2
    context.translateBy(x: marginX, y: CGFloat(pixels) - marginY)
    context.scaleBy(x: factor, y: -factor)
    context.translateBy(x: 20, y: 20)
    context.addPath(path)
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(27)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("status-icon\(suffix).png"))
}
