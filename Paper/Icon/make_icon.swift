// Draws Paper's app icon: a blank sheet of paper in a gilt frame on a dark
// gallery wall. Regenerate with Icon/make_icon.sh.
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.shadowColor = NSColor(white: 0, alpha: alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// Background tile, on Apple's 824pt grid inside the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
withShadow(blur: 28, y: -12, alpha: 0.35) {
    color(0x2B3532).setFill()
    tilePath.fill()
}
NSGradient(starting: color(0x3A4743), ending: color(0x1F2725))!.draw(in: tilePath, angle: -90)

// Frame: portrait, like a sheet of paper.
let frame = NSRect(x: 262, y: 196, width: 500, height: 632)
let border: CGFloat = 62
withShadow(blur: 30, y: -18, alpha: 0.5) {
    color(0x9A7638).setFill()
    NSBezierPath(rect: frame).fill()
}
// Gilt moulding: a gradient on each side, mitred at the corners.
let inner = frame.insetBy(dx: border, dy: border)
let sides: [([NSPoint], CGFloat)] = [
    ([NSPoint(x: frame.minX, y: frame.maxY), NSPoint(x: frame.maxX, y: frame.maxY),
      NSPoint(x: inner.maxX, y: inner.maxY), NSPoint(x: inner.minX, y: inner.maxY)], 90),   // top
    ([NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.minY),
      NSPoint(x: inner.maxX, y: inner.minY), NSPoint(x: inner.minX, y: inner.minY)], -90),  // bottom
    ([NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.minX, y: frame.maxY),
      NSPoint(x: inner.minX, y: inner.maxY), NSPoint(x: inner.minX, y: inner.minY)], 180),  // left
    ([NSPoint(x: frame.maxX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.maxY),
      NSPoint(x: inner.maxX, y: inner.maxY), NSPoint(x: inner.maxX, y: inner.minY)], 0),    // right
]
for (points, angle) in sides {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    // Lit from the top-left: top/left sides brighter.
    let light = angle == 90 || angle == 180
    NSGradient(colors: light
        ? [color(0x8A6427), color(0xE9C877), color(0xC49A4A)]
        : [color(0x6E4E1C), color(0xC0954A), color(0x9C7535)])!
        .draw(in: path, angle: angle + 180)
}
// Fine inner and outer beads.
color(0x5A3F14, 0.8).setStroke()
let outerBead = NSBezierPath(rect: frame.insetBy(dx: 3, dy: 3))
outerBead.lineWidth = 6
outerBead.stroke()
let innerBead = NSBezierPath(rect: inner.insetBy(dx: -4, dy: -4))
innerBead.lineWidth = 8
innerBead.stroke()
color(0xF3DC9C, 0.6).setStroke()
let highlight = NSBezierPath(rect: frame.insetBy(dx: border * 0.45, dy: border * 0.45))
highlight.lineWidth = 3
highlight.stroke()

// Dark backing inside the frame.
color(0x2A2620).setFill()
NSBezierPath(rect: inner).fill()

// The sheet of paper, with a turned-down top-right corner.
let sheet = inner.insetBy(dx: 30, dy: 30)
let fold: CGFloat = 70
let sheetPath = NSBezierPath()
sheetPath.move(to: NSPoint(x: sheet.minX, y: sheet.minY))
sheetPath.line(to: NSPoint(x: sheet.maxX, y: sheet.minY))
sheetPath.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
sheetPath.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
sheetPath.line(to: NSPoint(x: sheet.minX, y: sheet.maxY))
sheetPath.close()
withShadow(blur: 14, y: -6, alpha: 0.55) {
    color(0xF2ECDD).setFill()
    sheetPath.fill()
}
NSGradient(starting: color(0xFBF7EE), ending: color(0xE6DDC8))!.draw(in: sheetPath, angle: -60)

let flap = NSBezierPath()
flap.move(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
flap.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
flap.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
flap.close()
withShadow(blur: 10, y: -4, alpha: 0.35) {
    color(0xD8CDB4).setFill()
    flap.fill()
}
NSGradient(starting: color(0xEFE7D4), ending: color(0xCFC2A6))!.draw(in: flap, angle: 45)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
