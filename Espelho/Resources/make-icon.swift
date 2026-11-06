// Draws the Espelho app icon (1024×1024 PNG, Display P3). Usage: swift make-icon.swift out.png
//
// Concept: an iPhone in front of a Mac display, both showing the same sunset wallpaper —
// the phone's screen "mirrored" on the Mac. Deep night background, glass rims, soft light.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let P3 = CGColorSpace(name: CGColorSpace.displayP3)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: P3, components: [r, g, b, a])!
}
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: P3, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}
func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: P3,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Apple-style tile: rounded rectangle with continuous (superellipse) corners.
func squircle(_ r: CGRect, radius: CGFloat = 186) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = radius * 1.28  // corner span; curvature eases in like Apple's icon mask
    let n: CGFloat = 4
    // Sample a superellipse per quadrant, sized k, placed at each corner centre.
    let centres = [(CGPoint(x: r.maxX - k, y: r.maxY - k), 0.0), (CGPoint(x: r.minX + k, y: r.maxY - k), 0.5),
                   (CGPoint(x: r.minX + k, y: r.minY + k), 1.0), (CGPoint(x: r.maxX - k, y: r.minY + k), 1.5)]
    var first = true
    for (centre, start) in centres {
        for i in 0...90 {
            let t = (CGFloat(start) + CGFloat(i) / 180) * .pi
            let ct = cos(t), st = sin(t)
            let x = centre.x + k * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
            let y = centre.y + k * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
            if first { p.move(to: CGPoint(x: x, y: y)); first = false } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    p.closeSubpath()
    return p
}

/// Thin light rim along a shape: bright on top, fading toward the bottom (glass edge).
func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(c(1, 1, 1, top), 0), (c(1, 1, 1, bottom * 0.4), 0.55), (c(1, 1, 1, bottom), 1)]),
                           start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()
}

// MARK: Wallpaper shown on both screens

/// Sunset over layered hills, laid out relative to `r` so every screen shows the same scene.
func drawWallpaper(_ g: CGContext, in r: CGRect) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    g.drawLinearGradient(gradient([
        (c(0.22, 0.13, 0.62), 0),
        (c(0.62, 0.20, 0.78), 0.35),
        (c(1.00, 0.36, 0.52), 0.62),
        (c(1.00, 0.66, 0.32), 1),
    ]), start: pt(0, 0), end: pt(0, 1), options: [])
    let sun = pt(0.62, 0.70)
    let m = min(r.width, r.height)
    g.drawRadialGradient(gradient([(c(1, 0.95, 0.78, 1), 0), (c(1, 0.90, 0.65, 0.9), 0.18), (c(1, 0.70, 0.40, 0), 1)]),
                         startCenter: sun, startRadius: 0, endCenter: sun, endRadius: m * 0.75, options: [])
    let waves: [(CGFloat, CGFloat, CGColor)] = [
        (0.50, 0.10, c(0.96, 0.32, 0.56, 0.75)),
        (0.37, 0.12, c(0.58, 0.18, 0.74, 0.92)),
        (0.22, 0.10, c(0.27, 0.12, 0.56, 1)),
    ]
    for (base, amp, color) in waves {
        let p = CGMutablePath()
        p.move(to: pt(0, 0))
        p.addLine(to: pt(0, base))
        p.addCurve(to: pt(1, base + amp * 0.3), control1: pt(0.35, base + amp * 1.5), control2: pt(0.62, base - amp))
        p.addLine(to: pt(1, 0))
        p.closeSubpath()
        g.addPath(p)
        g.setFillColor(color)
        g.fillPath()
    }
}

/// Diagonal glare across a screen.
func glare(_ ctx: CGContext, _ rect: CGRect, strength: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.70))
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(c(1, 1, 1, strength), 0), (c(1, 1, 1, 0), 1)]),
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY - rect.height * 0.35), options: [])
    ctx.restoreGState()
}

// MARK: Icon

let ctx = bitmap(S, S)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)

// Drop shadow under the tile (macOS grid).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0, 0, 0, 0.38))
ctx.addPath(tilePath)
ctx.setFillColor(c(0.08, 0.06, 0.2))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Night-sky background with a violet glow behind the display and a cool glow lower left.
ctx.drawLinearGradient(gradient([(c(0.20, 0.15, 0.50), 0), (c(0.10, 0.08, 0.30), 0.55), (c(0.07, 0.06, 0.22), 1)]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 700, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.drawRadialGradient(gradient([(c(0.78, 0.36, 1.0, 0.60), 0), (c(0.78, 0.36, 1.0, 0), 1)]),
                       startCenter: CGPoint(x: 600, y: 610), startRadius: 0,
                       endCenter: CGPoint(x: 600, y: 610), endRadius: 430, options: [])
ctx.drawRadialGradient(gradient([(c(0.20, 0.60, 1.0, 0.45), 0), (c(0.20, 0.60, 1.0, 0), 1)]),
                       startCenter: CGPoint(x: 230, y: 230), startRadius: 0,
                       endCenter: CGPoint(x: 230, y: 230), endRadius: 380, options: [])

// --- Mac display (behind) ---
let display = CGRect(x: 318, y: 420, width: 548, height: 350)
let displayPath = rounded(display, 34)

// Stand: neck and foot.
let neck = CGMutablePath()
neck.move(to: CGPoint(x: display.midX - 44, y: display.minY + 2))
neck.addLine(to: CGPoint(x: display.midX + 44, y: display.minY + 2))
neck.addLine(to: CGPoint(x: display.midX + 58, y: 318))
neck.addLine(to: CGPoint(x: display.midX - 58, y: 318))
neck.closeSubpath()
let foot = rounded(CGRect(x: display.midX - 120, y: 300, width: 240, height: 24), 12)
for part in [neck, foot] {
    ctx.saveGState()
    ctx.addPath(part)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(c(0.86, 0.86, 0.92), 0), (c(0.55, 0.55, 0.65), 1)]),
                           start: CGPoint(x: display.midX - 120, y: 0), end: CGPoint(x: display.midX + 120, y: 0), options: [])
    ctx.restoreGState()
}
// Shade where the neck meets the display.
ctx.saveGState()
ctx.addPath(neck)
ctx.clip()
ctx.drawLinearGradient(gradient([(c(0, 0, 0, 0.45), 0), (c(0, 0, 0, 0), 1)]),
                       start: CGPoint(x: 0, y: display.minY), end: CGPoint(x: 0, y: display.minY - 40), options: [])
ctx.restoreGState()

// Bezel with shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0, 0, 0, 0.55))
ctx.addPath(displayPath)
ctx.setFillColor(c(0.05, 0.05, 0.08))
ctx.fillPath()
ctx.restoreGState()

let displayScreen = display.insetBy(dx: 14, dy: 14)
ctx.saveGState()
ctx.addPath(rounded(displayScreen, 22))
ctx.clip()
drawWallpaper(ctx, in: displayScreen)
glare(ctx, displayScreen, strength: 0.22)
ctx.restoreGState()
rim(ctx, displayPath, width: 3, top: 0.55, bottom: 0.08)

// Light spilling from the phone onto the display (the "mirroring").
ctx.saveGState()
ctx.addPath(rounded(displayScreen, 22))
ctx.clip()
ctx.drawRadialGradient(gradient([(c(1, 0.85, 0.75, 0.35), 0), (c(1, 0.85, 0.75, 0), 1)]),
                       startCenter: CGPoint(x: 420, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 420, y: 520), endRadius: 220, options: [])
ctx.restoreGState()

// --- iPhone (front) ---
let phone = CGRect(x: 178, y: 214, width: 236, height: 486)
let phonePath = rounded(phone, 56)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -22), blur: 46, color: c(0, 0, 0, 0.65))
ctx.addPath(phonePath)
ctx.setFillColor(c(0.6, 0.6, 0.66))
ctx.fillPath()
ctx.restoreGState()

// Titanium frame.
ctx.saveGState()
ctx.addPath(phonePath)
ctx.clip()
ctx.drawLinearGradient(gradient([(c(0.96, 0.95, 0.98), 0), (c(0.70, 0.70, 0.78), 0.45), (c(0.88, 0.88, 0.94), 0.7), (c(0.52, 0.52, 0.60), 1)]),
                       start: CGPoint(x: phone.minX, y: phone.maxY), end: CGPoint(x: phone.maxX, y: phone.minY), options: [])
ctx.restoreGState()

// Black glass, then the screen.
let glass = phone.insetBy(dx: 8, dy: 8)
ctx.addPath(rounded(glass, 48))
ctx.setFillColor(c(0.02, 0.02, 0.04))
ctx.fillPath()

let phoneScreen = glass.insetBy(dx: 9, dy: 9)
ctx.saveGState()
ctx.addPath(rounded(phoneScreen, 40))
ctx.clip()
drawWallpaper(ctx, in: phoneScreen)
glare(ctx, phoneScreen, strength: 0.30)
ctx.restoreGState()

// Dynamic Island.
ctx.addPath(rounded(CGRect(x: phone.midX - 40, y: phoneScreen.maxY - 40, width: 80, height: 24), 12))
ctx.setFillColor(c(0, 0, 0))
ctx.fillPath()

rim(ctx, phonePath, width: 2.5, top: 0.9, bottom: 0.15)

// Tile: soft top sheen and a glass edge.
ctx.drawLinearGradient(gradient([(c(1, 1, 1, 0.10), 0), (c(1, 1, 1, 0), 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()
rim(ctx, tilePath, width: 4, top: 0.45, bottom: 0.10)

// MARK: Save

let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("ícone: \(out)")
