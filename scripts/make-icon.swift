import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let frame = NSRect(x: 74, y: 74, width: 876, height: 876)
        let tile = NSBezierPath(roundedRect: frame, xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.31, blue: 0.91, alpha: 1),
                   ending: NSColor(srgbRed: 0.48, green: 0.32, blue: 0.97, alpha: 1))!.draw(in: tile, angle: 45)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        tile.lineWidth = 3; tile.stroke()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 245, y: 570))
        bolt.line(to: NSPoint(x: 575, y: 755))
        bolt.line(to: NSPoint(x: 525, y: 555))
        bolt.line(to: NSPoint(x: 790, y: 555))
        bolt.line(to: NSPoint(x: 453, y: 275))
        bolt.line(to: NSPoint(x: 500, y: 475))
        bolt.line(to: NSPoint(x: 245, y: 475))
        bolt.close()
        NSColor.white.setFill(); bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
