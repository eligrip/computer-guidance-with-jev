import AppKit

/// Render a synthetic comparison with the exact paths used by the live overlay.
/// swiftc Sources/JevAssist/HighlightStyle.swift scripts/render-highlight-styles.swift -o .build/render-highlight-styles
/// .build/render-highlight-styles artifacts/highlight-styles.png
@main
enum RenderHighlightStyles {
    static func main() throws {
        let width = 1000, height = 470, scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render preview") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSColor(srgbRed: 0.95, green: 0.97, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let ink = NSColor(srgbRed: 0.11, green: 0.17, blue: 0.19, alpha: 1)
        let secondary = NSColor(srgbRed: 0.37, green: 0.43, blue: 0.44, alpha: 1)
        func text(_ value: String, _ rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                               .foregroundColor: color ?? ink, .paragraphStyle: paragraph])
        }
        text("Choose your highlight", CGRect(x: 36, y: 389, width: 700, height: 44), size: 30, weight: .semibold)
        text("Three treatments for the same Download button.", CGRect(x: 36, y: 357, width: 800, height: 25), size: 16, color: secondary)
        for (index, style) in HighlightStyle.allCases.enumerated() {
            let x = CGFloat(36 + index * 316)
            let card = CGRect(x: x, y: 68, width: 296, height: 264)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
            text("0\(index + 1)", CGRect(x: x + 22, y: 293, width: 45, height: 19), size: 12, weight: .semibold, color: secondary)
            text(style.title, CGRect(x: x + 22, y: 259, width: 252, height: 27), size: 21, weight: .semibold)
            let stage = CGRect(x: x + 20, y: 140, width: 256, height: 100)
            NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
            NSBezierPath(roundedRect: stage, xRadius: 12, yRadius: 12).fill()
            let button = CGRect(x: x + 86, y: 168, width: 124, height: 44)
            NSColor.white.setFill()
            let buttonPath = NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8)
            buttonPath.fill()
            NSColor(srgbRed: 0.82, green: 0.85, blue: 0.87, alpha: 1).setStroke()
            buttonPath.lineWidth = 1
            buttonPath.stroke()
            text("Download", CGRect(x: button.minX + 23, y: button.minY + 12, width: 90, height: 22), size: 15, weight: .medium)
            HighlightDrawing.draw(style: style, target: button.insetBy(dx: -4, dy: -4))
            text(style.detail, CGRect(x: x + 22, y: 91, width: 252, height: 36), size: 14, color: secondary)
        }
        text("The highlight stays steady. You click, type, and scroll.", CGRect(x: 36, y: 26, width: 900, height: 22), size: 14, color: secondary)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        let path = CommandLine.arguments.dropFirst().first ?? "artifacts/highlight-styles.png"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print(url.path)
    }
}
