import CoreGraphics
import Foundation

/// Synthetic alpha/selection regressions for display-sized Dock backing windows.
/// No screen recording, real windows, permissions, network, or image files.
enum DockCaptureChecks {
    static func run() -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        func fixture(width: Int, height: Int, painted: CGRect?, backgroundAlpha: UInt8 = 0) -> CGImage {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let alpha: UInt8 = painted?.contains(CGPoint(x: x, y: y)) == true ? 255 : backgroundAlpha
                    bytes[(y * width + x) * 4 + 3] = alpha
                }
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let display = CGRect(x: 0, y: 0, width: 640, height: 480)
        let bar = CGRect(x: 120, y: 410, width: 400, height: 70)
        let image = fixture(width: 640, height: 480, painted: bar)
        let visible = DockSurfaceGeometry.visibleBounds(in: image, windowBounds: display, displays: [display])!
        expect(visible == CGRect(x: 118, y: 408, width: 404, height: 72), "display-sized Dock alpha resolves to actual bottom strip without vertical flip")
        let faint = fixture(width: 640, height: 480, painted: bar, backgroundAlpha: 16)
        expect(DockSurfaceGeometry.visibleBounds(in: faint, windowBounds: display, displays: [display]) == visible,
               "faint fullscreen shadow alpha does not enlarge or jitter Dock bounds")
        let opaque = fixture(width: 640, height: 480, painted: display)
        expect(DockSurfaceGeometry.visibleBounds(in: opaque, windowBounds: display, displays: [display]) == nil,
               "opaque fullscreen Dock surface is excluded")
        let hidden = fixture(width: 640, height: 480, painted: CGRect(x: 0, y: 479, width: 640, height: 1))
        expect(DockSurfaceGeometry.visibleBounds(in: hidden, windowBounds: display, displays: [display]) == nil,
               "auto-hide trigger strip is not treated as visible app icons")
        let transparent = fixture(width: 640, height: 480, painted: nil)
        expect(DockSurfaceGeometry.visibleBounds(in: transparent, windowBounds: display, displays: [display]) == nil,
               "transparent hidden Dock produces no target region")
        expect(DockSurfaceGeometry.assess(transparent, windowBounds: display, displays: [display]) == .absent,
               "successfully read empty Dock proves absence")
        expect(DockSurfaceGeometry.assess(hidden, windowBounds: display, displays: [display]) == .absent,
               "hidden Dock trigger proves absence of targetable icons")
        expect(DockSurfaceGeometry.assess(opaque, windowBounds: display, displays: [display]) == .unavailable,
               "unsupported fullscreen Dock image is uncertainty rather than disappearance")
        expect(DockSurfaceGeometry.assess(image, windowBounds: display, displays: []) == .unavailable,
               "missing display metadata cannot prove absence")
        let leftDisplay = CGRect(x: -640, y: -200, width: 640, height: 480)
        let side = fixture(width: 640, height: 480, painted: CGRect(x: 0, y: 80, width: 60, height: 320))
        expect(DockSurfaceGeometry.visibleBounds(in: side, windowBounds: leftDisplay, displays: [leftDisplay]) ==
               CGRect(x: -640, y: -122, width: 62, height: 324), "left-side Dock retains negative display coordinates")
        let retina = fixture(width: 1280, height: 960, painted: CGRect(x: 240, y: 820, width: 800, height: 140))
        let retinaBounds = DockSurfaceGeometry.visibleBounds(in: retina, windowBounds: display, displays: [display])!
        expect(abs(retinaBounds.minX - visible.minX) <= 2 && abs(retinaBounds.minY - visible.minY) <= 2 &&
               abs(retinaBounds.maxX - visible.maxX) <= 2 && abs(retinaBounds.maxY - visible.maxY) <= 2,
               "Retina alpha geometry maps back to desktop points")

        let backing = CaptureSurface(id: 7, processID: 20, layer: Int(CGWindowLevelForKey(.dockWindow)),
                                     bounds: display, alpha: 1, title: "Synthetic")
        let selected = CaptureSurfaceSelection.select([backing], foregroundPID: 99, dockPIDs: [20], displays: [display], pointer: .zero,
                                                     dockContentBounds: [7: visible])!
        expect(selected.surfaces.map(\.id) == [7] && selected.bounds == visible,
               "real-world fullscreen Dock metadata works without any foreground window or browser")
        expect(selected.dockBounds == [visible], "Dock geometry uses painted content rather than backing-window dimensions")
        expect(CaptureSurfaceSelection.select([backing], foregroundPID: 99, dockPIDs: [20], displays: [display], pointer: .zero,
                                             dockContentBounds: [:]) == nil, "unreadable/hidden Dock does not fall back to fullscreen capture")
        expect(CaptureSurfaceSelection.select([backing], foregroundPID: 99, dockPIDs: [30], displays: [display], pointer: .zero,
                                             dockContentBounds: [7: visible]) == nil, "unrelated process cannot become a Dock through cropped geometry")
        return checks
    }
}
