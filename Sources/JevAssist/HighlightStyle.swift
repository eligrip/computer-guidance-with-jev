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
        case .softOutline: return "A clear, soft outline surrounds the target."
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
        path.lineWidth = style == .underline ? 4 : 3.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        accent.setStroke()
        path.stroke()
    }
}
