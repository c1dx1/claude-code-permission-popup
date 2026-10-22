import AppKit

// Writes the app icon as an .iconset: Claude's clay-orange squircle with a cream spark.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

func drawIcon() {
    // macOS icon grid: an 824pt body centered on the 1024pt canvas.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    // No baked-in shadow: at card size it shows as a grey square around the icon.
    NSGradient(starting: NSColor(hex: 0xE2896A), ending: NSColor(hex: 0xC15C3A))?.draw(in: body, angle: -90)

    let center = NSPoint(x: 512, y: 512)
    let lengths: [CGFloat] = [292, 238, 280, 226, 300, 250, 272, 232, 296, 244, 284, 236]
    let jitter: [CGFloat] = [0, 4, -3, 2, -5, 3, 1, -4, 2, -2, 5, -1]
    NSColor(hex: 0xFAF9F5).setFill()
    for (index, length) in lengths.enumerated() {
        let degrees = CGFloat(index) * 30 + 15 + jitter[index]
        let angle = degrees * .pi / 180
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let tip = NSPoint(x: center.x + direction.dx * length, y: center.y + direction.dy * length)
        let base: CGFloat = 74, end: CGFloat = 40
        let ray = NSBezierPath()
        ray.move(to: NSPoint(x: center.x + normal.dx * base / 2, y: center.y + normal.dy * base / 2))
        ray.line(to: NSPoint(x: tip.x + normal.dx * end / 2, y: tip.y + normal.dy * end / 2))
        ray.appendArc(withCenter: tip, radius: end / 2, startAngle: degrees + 90, endAngle: degrees - 90, clockwise: true)
        ray.line(to: NSPoint(x: center.x - normal.dx * base / 2, y: center.y - normal.dy * base / 2))
        ray.close()
        ray.fill()
    }
    NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104)).fill()
}

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(pixels: points * scale)?.write(to: iconset.appendingPathComponent(name))
    }
}
