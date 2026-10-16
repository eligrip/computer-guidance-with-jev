import CoreGraphics
import Foundation

/// Finds the actual painted Dock inside a potentially display-sized transparent
/// Dock backing window. This receives only the already isolated Dock image; it
/// does not enumerate windows, capture the desktop, or inspect other apps.
enum DockSurfaceGeometry {
    enum Assessment: Equatable {
        case visible(CGRect)
        case absent
        case unavailable
    }

    static func visibleBounds(in image: CGImage, windowBounds: CGRect, displays: [CGRect]) -> CGRect? {
        guard case .visible(let bounds) = assess(image, windowBounds: windowBounds, displays: displays) else { return nil }
        return bounds
    }

    static func assess(_ image: CGImage, windowBounds: CGRect, displays: [CGRect]) -> Assessment {
        guard image.width > 0, image.height > 0, windowBounds.width > 0, windowBounds.height > 0, !displays.isEmpty else { return .unavailable }
        // Keep geometry detection cheap and independent of Retina resolution.
        // Ignore faint shadow/backdrop alpha to avoid bounding-box jitter.
        let scale = min(1, 768 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return .unavailable }
        var minX = width, minY = height, maxX = -1, maxY = -1
        var painted = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 48 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                painted += 1
            }
        }
        guard maxX >= minX, maxY >= minY, painted >= 32 else { return .absent }
        let scaleX = windowBounds.width / CGFloat(width)
        let scaleY = windowBounds.height / CGFloat(height)
        let visible = CGRect(x: windowBounds.minX + CGFloat(minX) * scaleX,
                             y: windowBounds.minY + CGFloat(minY) * scaleY,
                             width: CGFloat(maxX - minX + 1) * scaleX,
                             height: CGFloat(maxY - minY + 1) * scaleY)
            .insetBy(dx: -2, dy: -2).integral.intersection(windowBounds)
        // A fullscreen/opaque Dock-owned surface (for example an overview) is
        // not the app-launching strip. Never broaden capture to such a surface.
        guard let display = displays.first(where: { CaptureSurfaceSelection.isVisibleDockStrip(visible, on: $0) }) else {
            // A hidden Dock's tiny trigger strip is known absence. An opaque
            // fullscreen/unsupported surface is uncertainty, not proof that
            // all useful content disappeared.
            if visible.width < 16 || visible.height < 16 { return .absent }
            return .unavailable
        }
        return .visible(visible.intersection(display))
    }
}
