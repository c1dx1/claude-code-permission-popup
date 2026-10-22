import AppKit

// compose OUT RADIUS_PX IN... : rounds each input, stacks them vertically, adds a soft shadow around each.
let args = CommandLine.arguments
let radius = CGFloat(Double(args[2])!)
let inputs = args[3...].map { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: $0)))! }
let pad: CGFloat = 72, gap: CGFloat = 20
let width = inputs.map { CGFloat($0.pixelsWide) }.max()! + pad * 2
let height = inputs.reduce(pad * 2 - gap) { $0 + CGFloat($1.pixelsHigh) + gap }

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func rounded(_ rep: NSBitmapImageRep) -> NSImage {
    let out = bitmap(rep.pixelsWide, rep.pixelsHigh)
    let rect = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    rep.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: rect.size)
    image.addRepresentation(out)
    return image
}

let canvas = bitmap(Int(width), Int(height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
var top = height - pad
for rep in inputs {
    let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    let rect = NSRect(x: width - pad - size.width, y: top - size.height, width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    rounded(rep).draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    border.lineWidth = 1
    NSColor.black.withAlphaComponent(0.10).setStroke()
    border.stroke()
    top -= size.height + gap
}
NSGraphicsContext.restoreGraphicsState()
try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
