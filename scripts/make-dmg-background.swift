import AppKit
import Foundation

// Generate both resolutions from vectors; tiffutil combines them into a Retina background.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale)); transform.concat()
    let canvas = NSRect(x: 0, y: 0, width: 640, height: 400)
    NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.985, blue: 1, alpha: 1),
        ending: NSColor(srgbRed: 0.93, green: 0.94, blue: 0.99, alpha: 1))!.draw(in: canvas, angle: -45)
    let ink = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.25, alpha: 1)
    let secondary = NSColor(srgbRed: 0.47, green: 0.51, blue: 0.59, alpha: 1)
    let accent = NSColor(srgbRed: 0.24, green: 0.32, blue: 0.92, alpha: 1)
    func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking]
        let string = NSAttributedString(string: value, attributes: attributes)
        string.draw(at: NSPoint(x: x, y: 400 - top - string.size().height))
    }
    text("THUNDERBRIDGE", x: 48, top: 30, size: 11, weight: .semibold, color: accent, tracking: 2.4)
    text("安装雷桥", x: 46, top: 57, size: 28, weight: .semibold, color: ink)
    text("拖入「应用程序」，即可完成安装。", x: 48, top: 102, size: 13, weight: .regular, color: secondary)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 292, y: 400 - 220)); arrow.line(to: NSPoint(x: 348, y: 400 - 220))
    arrow.move(to: NSPoint(x: 338, y: 400 - 210)); arrow.line(to: NSPoint(x: 348, y: 400 - 220)); arrow.line(to: NSPoint(x: 338, y: 400 - 230))
    accent.withAlphaComponent(0.55).setStroke(); arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x: 48, y: 54)); line.line(to: NSPoint(x: 592, y: 54))
    secondary.withAlphaComponent(0.18).setStroke(); line.lineWidth = 1; line.stroke()
    text("macOS 13+", x: 48, top: 365, size: 10, weight: .medium, color: secondary)
    text("Apple Silicon · Intel", x: 492, top: 365, size: 10, weight: .medium, color: secondary)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: 640, height: 400)
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
