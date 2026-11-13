// Draws the -196 app icon (a drinks can with "-196" on it) and writes icon/AppIcon.icns.
// Usage: swift icon/make-icon.swift
import AppKit

func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws the icon into a 1024-unit square; the context is scaled for other sizes.
func draw() {
    // Background: the rounded square macOS icons sit on (824 of 1024, per Apple's grid).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    colour(12, 28, 60).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [colour(10, 22, 52), colour(22, 78, 140), colour(120, 200, 235)])!.draw(in: tilePath, angle: 90)

    // A few frost specks.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    var seed: UInt64 = 196
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10_000) / 10_000
    }
    for _ in 0..<70 {
        let x = 100 + random() * 824, y = 100 + random() * 824, r = 2 + random() * 5
        NSColor.white.withAlphaComponent(0.12 + random() * 0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The can, tilted a little.
    NSGraphicsContext.saveGraphicsState()
    let turn = NSAffineTransform()
    turn.translateX(by: 512, yBy: 512)
    turn.rotate(byDegrees: -8)
    turn.translateX(by: -512, yBy: -512)
    turn.concat()

    let left: CGFloat = 332, right: CGFloat = 692, bottom: CGFloat = 215, top: CGFloat = 790
    let width = right - left, curve: CGFloat = 34          // half-height of the end ellipses
    let neck: CGFloat = 26                                  // how far the can narrows at the ends

    // Body outline: straight sides, narrowed shoulders, curved bottom.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: left + neck, y: top))
    body.line(to: NSPoint(x: left, y: top - 60))
    body.line(to: NSPoint(x: left, y: bottom + 50))
    body.line(to: NSPoint(x: left + neck, y: bottom))
    body.curve(to: NSPoint(x: right - neck, y: bottom),
               controlPoint1: NSPoint(x: left + neck + 60, y: bottom - curve * 1.3),
               controlPoint2: NSPoint(x: right - neck - 60, y: bottom - curve * 1.3))
    body.line(to: NSPoint(x: right, y: bottom + 50))
    body.line(to: NSPoint(x: right, y: top - 60))
    body.line(to: NSPoint(x: right - neck, y: top))
    body.close()

    NSGraphicsContext.saveGraphicsState()
    let canShadow = NSShadow()
    canShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    canShadow.shadowOffset = NSSize(width: 0, height: -14)
    canShadow.shadowBlurRadius = 30
    canShadow.set()
    colour(200, 210, 220).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Metal: light in the middle-left, darker towards the edges.
    NSGradient(colorsAndLocations:
        (colour(120, 132, 148), 0), (colour(236, 242, 248), 0.28), (colour(250, 252, 255), 0.4),
        (colour(190, 200, 212), 0.7), (colour(104, 116, 134), 1))!.draw(in: body, angle: 0)

    // Label band.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let label = NSBezierPath()
    let labelTop = top - 120, labelBottom = bottom + 105
    label.move(to: NSPoint(x: left, y: labelTop))
    label.curve(to: NSPoint(x: right, y: labelTop),
                controlPoint1: NSPoint(x: left + 90, y: labelTop - curve), controlPoint2: NSPoint(x: right - 90, y: labelTop - curve))
    label.line(to: NSPoint(x: right, y: labelBottom))
    label.curve(to: NSPoint(x: left, y: labelBottom),
                controlPoint1: NSPoint(x: right - 90, y: labelBottom - curve), controlPoint2: NSPoint(x: left + 90, y: labelBottom - curve))
    label.close()
    NSGradient(colorsAndLocations:
        (colour(6, 30, 78), 0), (colour(24, 92, 178), 0.3), (colour(40, 120, 205), 0.42),
        (colour(14, 60, 130), 0.72), (colour(4, 22, 60), 1))!.draw(in: label, angle: 0)

    // "-196"
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let font = NSFont.systemFont(ofSize: 150, weight: .heavy)
    let text = NSAttributedString(string: "-196", attributes: [
        .font: font, .foregroundColor: NSColor.white, .paragraphStyle: style, .kern: -4,
    ])
    let textHeight = text.size().height
    let middle = (labelTop + labelBottom) / 2 - curve / 2
    text.draw(in: NSRect(x: left, y: middle - textHeight / 2, width: width, height: textHeight))

    // A thin frost line under the text.
    colour(170, 225, 250, 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: left + 95, y: middle - textHeight / 2 - 6, width: width - 190, height: 9),
                 xRadius: 4.5, yRadius: 4.5).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Highlight down the left side.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: left + 50, y: bottom, width: 60, height: top - bottom), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // Lid: rim ellipse, inner lid, opening and tab.
    let rim = NSRect(x: left + neck, y: top - curve, width: width - 2 * neck, height: curve * 2)
    NSGradient(colors: [colour(150, 160, 174), colour(245, 248, 252)])!.draw(in: NSBezierPath(ovalIn: rim), angle: 90)
    let lid = rim.insetBy(dx: 16, dy: 7)
    NSGradient(colors: [colour(205, 212, 222), colour(160, 170, 184)])!.draw(in: NSBezierPath(ovalIn: lid), angle: 90)
    colour(40, 50, 66).setFill()
    NSBezierPath(ovalIn: NSRect(x: lid.midX - 62, y: lid.midY - 13, width: 58, height: 22)).fill()
    colour(232, 236, 242).setFill()
    NSBezierPath(ovalIn: NSRect(x: lid.midX - 6, y: lid.midY - 11, width: 74, height: 22)).fill()
    colour(150, 160, 174).setFill()
    NSBezierPath(ovalIn: NSRect(x: lid.midX + 26, y: lid.midY - 5, width: 28, height: 10)).fill()

    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try png(pixels: points * scale).write(to: set.appendingPathComponent(name))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", set.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(tool.terminationStatus == 0 ? "wrote icon/AppIcon.icns" : "iconutil failed")
