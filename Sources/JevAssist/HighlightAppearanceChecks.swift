import AppKit

/// Synthetic geometry, rendering and cue checks. No windows are shown and no
/// screen content, permissions, audio, or persisted preferences are accessed.
@MainActor
enum HighlightAppearanceChecks {
    static func run() -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        expect(HighlightStyle.restored(nil) == .softOutline, "soft outline remains the default")
        expect(HighlightDrawing.lineWidth(for: .softOutline) == 5.5, "soft outline is bold enough to notice")
        let exact = CGRect(x: 100, y: 200, width: 160, height: 40)
        let visual = HighlightDrawing.visualTarget(for: exact)
        expect(visual == CGRect(x: 96, y: 196, width: 168, height: 48), "visual outline expands outside the actionable target")
        let panel = HighlightOverlay.cocoaRect(for: exact, primaryDisplayHeight: 900)
        let localTarget = CGRect(origin: .zero, size: panel.size).insetBy(
            dx: HighlightDrawing.overlayPadding - HighlightDrawing.targetOutset,
            dy: HighlightDrawing.overlayPadding - HighlightDrawing.targetOutset)
        expect(panel.minX + localTarget.minX == visual.minX
               && 900 - (panel.minY + localTarget.maxY) == visual.minY,
               "extra pulse padding never moves the target")
        let start = HighlightArrivalCue(elapsed: 0, reduceMotion: false)!
        let later = HighlightArrivalCue(elapsed: 0.4, reduceMotion: false)!
        expect(later.expansion > start.expansion && later.opacity < start.opacity, "arrival halo expands and fades once")
        expect(HighlightArrivalCue(elapsed: HighlightArrivalCue.duration, reduceMotion: false) == nil,
               "arrival cue ends and cannot animate forever")
        expect(HighlightArrivalCue(elapsed: 0.2, reduceMotion: true) == nil, "Reduce Motion disables the arrival animation")
        expect(HighlightArrivalCue(elapsed: -0.1, reduceMotion: false) == nil
               && HighlightArrivalCue(elapsed: .infinity, reduceMotion: false) == nil,
               "invalid cue times do not draw")
        expect(HighlightDrawing.targetOutset + 14 + 3 <= HighlightDrawing.overlayPadding,
               "panel padding contains the entire arrival halo")
        let target = CGRect(x: 40, y: 40, width: 140, height: 40)
        for style in HighlightStyle.allCases {
            let steady = bitmap(width: 220, height: 120) {
                HighlightDrawing.draw(style: style, target: HighlightDrawing.visualTarget(for: target))
            }
            expect(steady.colorAt(x: 110, y: 60)!.alphaComponent == 0,
                   "\(style.rawValue) leaves the target content unobscured")
            let reducedMotion = bitmap(width: 220, height: 120) {
                let visual = HighlightDrawing.visualTarget(for: target)
                HighlightDrawing.drawArrival(target: visual, elapsed: 0.2, reduceMotion: true)
                HighlightDrawing.draw(style: style, target: visual)
            }
            expect(pixelData(steady) == pixelData(reducedMotion),
                   "\(style.rawValue) with Reduce Motion draws the exact steady style")
        }
        return checks
    }

    /// The preview uses the same drawing functions as the real transparent
    /// overlay, including a frozen frame of its short arrival cue.
    static func renderPreview(to url: URL) throws {
        let preview = bitmap(width: 1120, height: 610) {
            NSColor(srgbRed: 0.96, green: 0.97, blue: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1120, height: 610).fill()
            text("A stronger guide, with a brief arrival cue", at: CGPoint(x: 34, y: 554), size: 26, weight: .semibold)
            text("The border stays steady after the cue. Reduce Motion skips the animation.", at: CGPoint(x: 35, y: 524), size: 14)
            for (label, x) in [("Light screen", 230), ("Dark screen", 510), ("New guidance · 0.22s", 790)] {
                text(label, at: CGPoint(x: x, y: 485), size: 14, weight: .semibold)
            }
            for (index, style) in HighlightStyle.allCases.enumerated() {
                let y = CGFloat(345 - index * 145)
                text(style.title, at: CGPoint(x: 35, y: y + 62), size: 18, weight: .semibold)
                for column in 0..<3 {
                    let x = CGFloat(220 + column * 280)
                    let sample = CGRect(x: x, y: y, width: 260, height: 120)
                    let dark = column == 1
                    (dark ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.14, alpha: 1) : .white).setFill()
                    NSBezierPath(roundedRect: sample, xRadius: 14, yRadius: 14).fill()
                    let button = CGRect(x: x + 60, y: y + 40, width: 140, height: 40)
                    (dark ? NSColor(srgbRed: 0.22, green: 0.25, blue: 0.27, alpha: 1)
                          : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: button, xRadius: 7, yRadius: 7).fill()
                    let title: NSString = "Download"
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                        .foregroundColor: dark ? NSColor.white : NSColor.black
                    ]
                    let size = title.size(withAttributes: attributes)
                    title.draw(at: CGPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2), withAttributes: attributes)
                    let visual = HighlightDrawing.visualTarget(for: button)
                    if column == 2 { HighlightDrawing.drawArrival(target: visual, elapsed: 0.22, reduceMotion: false) }
                    HighlightDrawing.draw(style: style, target: visual)
                }
            }
        }
        guard let data = preview.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "HighlightPreview", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    private static func pixelData(_ image: NSBitmapImageRep) -> Data {
        Data(bytes: image.bitmapData!, count: image.bytesPerRow * image.pixelsHigh)
    }

    private static func text(_ text: String, at point: CGPoint, size: CGFloat,
                             weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(srgbRed: 0.13, green: 0.17, blue: 0.18, alpha: 1)
        ])
    }
}
