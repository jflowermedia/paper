// Draws Paper's app icon (1024x1024): a framed landscape, in Catppuccin Mocha, with a
// little glass to it, to match Keeper's. https://catppuccin.com/palette/
// Regenerate with Icon/make_icon.sh.
import AppKit
import CoreImage

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Palette

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255,
                                            CGFloat(hex >> 8 & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}

let peach: UInt32 = 0xfab387, yellow: UInt32 = 0xf9e2af, rosewater: UInt32 = 0xf5e0dc
let maroon: UInt32 = 0xeba0ac
let subtext: UInt32 = 0xbac2de, overlay: UInt32 = 0x7f849c, surface2: UInt32 = 0x585b70
let surface1: UInt32 = 0x45475a, surface0: UInt32 = 0x313244, base: UInt32 = 0x1e1e2e
let mantle: UInt32 = 0x181825, crust: UInt32 = 0x11111b
let white: UInt32 = 0xffffff

// MARK: Drawing

func canvas() -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y down, so the coordinates read like the design's.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

func blurred(_ radius: Double, _ draw: (CGContext) -> Void) -> CGImage {
    let context = canvas()
    draw(context)
    let image = CIImage(cgImage: context.makeImage()!)
    let soft = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return CIContext(options: [.workingColorSpace: space])
        .createCGImage(soft, from: image.extent, format: .RGBA8, colorSpace: space)!
}

func put(_ image: CGImage, on context: CGContext, down: CGFloat = 0) {
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(size) + down)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    context.restoreGState()
}

func fill(_ path: CGPath, on context: CGContext, _ colours: [CGColor], _ stops: [CGFloat],
          from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace: space, colors: colours as CFArray, locations: stops)!,
                               start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func outline(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// Light or shade falling inside a shape from its own edge.
func inside(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat, soft: Double) {
    let shade = blurred(soft) { c in
        c.setFillColor(tint)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        c.setBlendMode(.clear)
        c.translateBy(x: x, y: y)
        c.addPath(path)
        c.fillPath()
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    put(shade, on: context)
    context.restoreGState()
}

func over(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.addPath(path)
    context.setFillColor(tint)
    context.fillPath()
    context.restoreGState()
}

// MARK: Shapes

let plate = CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                   cornerWidth: 188, cornerHeight: 188, transform: nil)

let frameBox = CGRect(x: 274, y: 204, width: 476, height: 616)
let frameOuter = CGPath(roundedRect: frameBox, cornerWidth: 46, cornerHeight: 46, transform: nil)
let openingBox = frameBox.insetBy(dx: 66, dy: 66)
let opening = CGPath(roundedRect: openingBox, cornerWidth: 24, cornerHeight: 24, transform: nil)
/// The picture sits inside the opening with a dark gap round it, so the hill stands off the frame.
let pictureBox = openingBox.insetBy(dx: 20, dy: 20)
let picture = CGPath(roundedRect: pictureBox, cornerWidth: 12, cornerHeight: 12, transform: nil)

let sun = CGPath(ellipseIn: CGRect(x: 528, y: 336, width: 100, height: 100), transform: nil)

/// One hill across the picture, higher on the left.
let hill: CGPath = {
    let path = CGMutablePath()
    let b = pictureBox
    path.move(to: CGPoint(x: b.minX, y: b.maxY))
    path.addLine(to: CGPoint(x: b.minX, y: 566))
    path.addCurve(to: CGPoint(x: b.maxX, y: 636), control1: CGPoint(x: 440, y: 452), control2: CGPoint(x: 560, y: 640))
    path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
    path.closeSubpath()
    return path.intersection(picture)
}()

// MARK: The icon

let icon = canvas()

// The plate: lighter at the top, with a breath of the frame's colours in two corners.
fill(plate, on: icon, [colour(surface0), colour(base)], [0, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))
icon.saveGState()
icon.addPath(plate)
icon.clip()
put(blurred(100) { c in
    for (centre, radius, tint) in [(CGPoint(x: 300, y: 280), CGFloat(190), yellow),
                                   (CGPoint(x: 740, y: 780), CGFloat(210), peach)] {
        c.setFillColor(colour(tint, 0.13))
        c.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: 2 * radius, height: 2 * radius))
    }
}, on: icon)
put(blurred(20) { $0.addPath(frameOuter); $0.setFillColor(colour(crust, 0.6)); $0.fillPath() }, on: icon, down: 16)
icon.restoreGState()

// Light along the plate's top edge, fading. Without it the plate is lost on a dark Dock.
fill(outline(CGPath(roundedRect: CGRect(x: 94.5, y: 94.5, width: 835, height: 835),
                    cornerWidth: 185.5, cornerHeight: 185.5, transform: nil), 5),
     on: icon, [colour(overlay), colour(surface2, 0.35), colour(surface1, 0.25)], [0, 0.45, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))

// The frame: lit from above, a little from below, and round its edge.
let tl = CGPoint(x: frameBox.minX, y: frameBox.minY), br = CGPoint(x: frameBox.maxX, y: frameBox.maxY)
fill(frameOuter, on: icon, [colour(yellow), colour(peach)], [0, 1], from: tl, to: br)
fill(frameOuter, on: icon, [colour(white, 0.20), colour(white, 0)], [0, 1], from: tl, to: CGPoint(x: tl.x, y: tl.y + 210))
fill(frameOuter, on: icon, [colour(white, 0), colour(white, 0.10)], [0, 1], from: CGPoint(x: 0, y: br.y - 120), to: CGPoint(x: 0, y: br.y))
icon.saveGState()
icon.addPath(frameOuter)
icon.clip()
put(blurred(6) { $0.addPath(outline(frameOuter, 12)); $0.setFillColor(colour(white, 0.5)); $0.fillPath() }, on: icon)
fill(outline(frameOuter, 7), on: icon, [colour(white, 0.9), colour(white, 0.11), colour(white, 0.5)], [0, 0.5, 1], from: tl, to: br)
icon.restoreGState()

// The opening is cut in, softly: a lit lower lip, and shade under the top edge.
over(opening, on: icon, colour(white, 0.42), x: 1, y: 3.5)
fill(opening, on: icon, [colour(base), colour(surface0)], [0, 1],
     from: CGPoint(x: 0, y: openingBox.minY), to: CGPoint(x: 0, y: openingBox.maxY))

// The painting: a sun, with a little glow, over one hill.
icon.saveGState()
icon.addPath(opening)
icon.clip()
put(blurred(34) { $0.addPath(sun); $0.setFillColor(colour(yellow, 0.45)); $0.fillPath() }, on: icon)
fill(sun, on: icon, [colour(rosewater), colour(yellow)], [0, 1], from: CGPoint(x: 0, y: 336), to: CGPoint(x: 0, y: 436))
fill(hill, on: icon, [colour(peach), colour(maroon)], [0, 1], from: CGPoint(x: 360, y: 500), to: CGPoint(x: 660, y: 734))
icon.restoreGState()
inside(hill, on: icon, colour(white, 0.35), y: 4, soft: 3)
inside(opening, on: icon, colour(crust, 0.85), x: 1, y: 8, soft: 8)

let path = CommandLine.arguments.dropFirst().first ?? "icon.png"
try! NSBitmapImageRep(cgImage: icon.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
