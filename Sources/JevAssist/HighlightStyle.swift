import AppKit

enum HighlightStyle: String, CaseIterable, Identifiable {
    case softOutline, corners, underline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .softOutline: return "Soft outline"
        case .corners: return "Corner guides"
        case .underline: return "Underline"
        }
    }
    var detail: String {
        switch self {
        case .softOutline: return "A bold outline stays clear on light and dark screens."
        case .corners: return "Four small corners leave the control clear."
        case .underline: return "A quiet marker just below the target."
        }
    }

    static func restored(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .softOutline
    }
}

/// Shared by the real overlay and its previews. Paths stay in screen points;
/// AppKit rasterizes them at the destination display's backing scale.
enum HighlightDrawing {
    static let accent = NSColor(srgbRed: 0.0, green: 0.69, blue: 0.62, alpha: 1)
    static let overlayPadding: CGFloat = 24
    static let targetOutset: CGFloat = 4

    static func lineWidth(for style: HighlightStyle) -> CGFloat {
        switch style {
        case .softOutline: return 5.5
        case .corners: return 4.5
        case .underline: return 5
        }
    }

    /// The visual border sits just outside the exact actionable target. The
    /// overlay and static style previews use this same visual outset.
    static func visualTarget(for target: CGRect) -> CGRect {
        target.insetBy(dx: -targetOutset, dy: -targetOutset)
    }

    static func drawArrival(target: CGRect, elapsed: TimeInterval, reduceMotion: Bool) {
        guard let cue = HighlightArrivalCue(elapsed: elapsed, reduceMotion: reduceMotion) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = true
        let halo = target.insetBy(dx: -cue.expansion, dy: -cue.expansion)
        let radius = min(12, min(target.width, target.height) * 0.22) + cue.expansion
        let path = NSBezierPath(roundedRect: halo, xRadius: radius, yRadius: radius)
        path.lineWidth = 6
        NSColor.white.withAlphaComponent(cue.opacity * 0.8).setStroke()
        path.stroke()
        path.lineWidth = 3.5
        accent.withAlphaComponent(cue.opacity).setStroke()
        path.stroke()
    }

    static func draw(style: HighlightStyle, target: CGRect) {
        guard target.width > 0, target.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = true
        let path = NSBezierPath()
        let radius = min(12, min(target.width, target.height) * 0.22)
        switch style {
        case .softOutline:
            path.appendRoundedRect(target, xRadius: radius, yRadius: radius)
        case .corners:
            let length = min(22, min(target.width, target.height) * 0.4)
            let curve = min(radius, length * 0.65)
            // Build each rounded corner independently, leaving open edges.
            for (x, y, dx, dy) in [
                (target.minX, target.minY, CGFloat(1), CGFloat(1)),
                (target.maxX, target.minY, CGFloat(-1), CGFloat(1)),
                (target.minX, target.maxY, CGFloat(1), CGFloat(-1)),
                (target.maxX, target.maxY, CGFloat(-1), CGFloat(-1))
            ] {
                path.move(to: NSPoint(x: x + dx * length, y: y))
                path.line(to: NSPoint(x: x + dx * curve, y: y))
                path.curve(to: NSPoint(x: x, y: y + dy * curve),
                           controlPoint1: NSPoint(x: x + dx * curve * 0.45, y: y),
                           controlPoint2: NSPoint(x: x, y: y + dy * curve * 0.45))
                path.line(to: NSPoint(x: x, y: y + dy * length))
            }
        case .underline:
            // Kept outside the target, within the overlay's padding.
            path.move(to: NSPoint(x: target.minX + radius, y: target.minY - 1))
            path.line(to: NSPoint(x: target.maxX - radius, y: target.minY - 1))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Contrast bands keep the teal visible over both pale pages and dark
        // controls without filling or obscuring the content inside the target.
        let width = lineWidth(for: style)
        path.lineWidth = width + 4
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.stroke()
        path.lineWidth = width + 2
        NSColor.white.withAlphaComponent(0.98).setStroke()
        path.stroke()
        path.lineWidth = width
        accent.setStroke()
        path.stroke()
    }
}

/// One arrival cue, never a continuing pulse. Reduced Motion uses the steady
/// high-contrast outline immediately, with no movement or opacity animation.
struct HighlightArrivalCue {
    static let duration: TimeInterval = 0.85
    let expansion: CGFloat
    let opacity: CGFloat

    init?(elapsed: TimeInterval, reduceMotion: Bool) {
        guard !reduceMotion, elapsed.isFinite, elapsed >= 0, elapsed < Self.duration else { return nil }
        let progress = elapsed / Self.duration
        let eased = 1 - pow(1 - progress, 3)
        expansion = CGFloat(2 + 12 * eased)
        opacity = CGFloat(0.85 * pow(1 - progress, 1.3))
    }
}
