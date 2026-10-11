// Draws the Lamp Bar app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
// A near-black macOS rounded square with one warm-glowing lamp, simple enough to read at 16 px.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024-unit canvas, y down, scaled to `pixels`.
func icon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: s, y: -s)

    // The macOS icon shape: 824 units with 100-unit margins, and a soft shadow under it.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    color(0x0B0B0D).setFill()
    shape.fill()
    cg.restoreGState()

    cg.saveGState()
    shape.addClip()
    NSGradient(starting: color(0x2A2B2F), ending: color(0x08080A))!.draw(in: tile, angle: 90)
    // Warm light spreading from the lamp.
    let center = NSPoint(x: 512, y: 470)
    NSGradient(colors: [color(0xFFB866, 0.55), color(0xFF9F43, 0.18), color(0xFF9F43, 0)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 400, options: [])
    // A pool of light on the surface under the lamp.
    let pool = NSBezierPath(ovalIn: NSRect(x: 262, y: 650, width: 500, height: 110))
    NSGradient(colors: [color(0xFFC98A, 0.5), color(0xFFC98A, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: pool, relativeCenterPosition: .zero)
    cg.restoreGState()

    // The lamp: a glowing glass dome on a short stem (the mushroom lamp), with a dark foot.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60, color: color(0xFFB866, 0.9).cgColor)
    let dome = NSBezierPath()
    dome.move(to: NSPoint(x: 312, y: 480))
    dome.appendArc(withCenter: NSPoint(x: 512, y: 480), radius: 200, startAngle: 180, endAngle: 0, clockwise: false)
    dome.close()
    let stem = NSBezierPath(roundedRect: NSRect(x: 432, y: 470, width: 160, height: 190), xRadius: 44, yRadius: 44)
    let glass = NSBezierPath()
    glass.append(dome)
    glass.append(stem)
    cg.saveGState()
    glass.addClip()
    // Brightest at the bulb inside the glass, warmer toward the edges.
    let bulb = NSPoint(x: 512, y: 500)
    NSGradient(colors: [color(0xFFFAF0), color(0xFFDDA6), color(0xFFB45E)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: bulb, radius: 0, toCenter: bulb, radius: 270, options: [.drawsAfterEndingLocation])
    cg.restoreGState()
    cg.restoreGState()
    color(0x3A3D41).setFill()
    NSBezierPath(roundedRect: NSRect(x: 362, y: 676, width: 300, height: 34), xRadius: 17, yRadius: 17).fill()

    // A thin light edge on the tile.
    color(0xFFFFFF, 0.07).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    edge.lineWidth = 4
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try icon(pixels: points * scale).write(to: out.appendingPathComponent(name))
    }
}
