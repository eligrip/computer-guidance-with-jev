import CoreGraphics
import Foundation

/// Window-server metadata only. Selection is pure so privacy scope can be tested
/// without recording the user's screen or depending on their window layout.
struct CaptureSurface {
    let id: CGWindowID
    let processID: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let title: String
}

struct CaptureSelection {
    let anchor: CaptureSurface
    /// Front-to-back order from CGWindowListCopyWindowInfo.
    let surfaces: [CaptureSurface]
    let bounds: CGRect
    let surfaceBounds: [CGRect]
    let dockSurfaces: [CaptureSurface]
    let dockBounds: [CGRect]
}

enum CaptureSurfaceSelection {
    static func select(_ surfaces: [CaptureSurface], foregroundPID: pid_t,
                       dockPIDs: Set<pid_t>, displays: [CGRect], pointer: CGPoint,
                       dockLayer: Int = Int(CGWindowLevelForKey(.dockWindow))) -> CaptureSelection? {
        guard !displays.isEmpty else { return nil }
        let eligible = surfaces.filter { surface in
            surface.alpha > 0 && surface.bounds.width > 10 && surface.bounds.height > 10 &&
            [surface.bounds.minX, surface.bounds.minY, surface.bounds.width, surface.bounds.height].allSatisfy(\.isFinite)
        }
        let mainIndex = eligible.firstIndex {
            $0.processID == foregroundPID && $0.layer == 0 && $0.bounds.width > 100 && $0.bounds.height > 80
        } ?? eligible.firstIndex {
            $0.processID == foregroundPID && $0.layer == 0
        }
        let main = mainIndex.map { eligible[$0] }
        let display: CGRect
        if let main, let largest = displays.max(by: { area($0.intersection(main.bounds)) < area($1.intersection(main.bounds)) }),
           area(largest.intersection(main.bounds)) > 0 {
            display = largest
        } else {
            display = displays.first(where: { $0.contains(pointer) }) ?? displays[0]
        }

        // A Dock process also owns wallpaper and other desktop-sized surfaces.
        // Its PID alone is insufficient: require the documented Dock window
        // level and a visible strip at the bottom, left, or right display edge.
        let docks = eligible.filter {
            dockPIDs.contains($0.processID) && $0.layer == dockLayer && isVisibleDockStrip($0.bounds, on: display)
        }
        let dockIDs = Set(docks.map(\.id))
        let appIDs: Set<CGWindowID> = mainIndex.map { index in
            Set(eligible.prefix(index + 1).filter {
                $0.processID == foregroundPID && area($0.bounds.intersection(display)) > 100
            }.map(\.id))
        } ?? []
        let selected = eligible.filter { appIDs.contains($0.id) || dockIDs.contains($0.id) }
        guard let anchor = main ?? docks.first, !selected.isEmpty else { return nil }
        let clipped = selected.map { $0.bounds.intersection(display) }
        let union = clipped.dropFirst().reduce(clipped[0]) { $0.union($1) }
        return CaptureSelection(anchor: anchor, surfaces: selected, bounds: union,
                                surfaceBounds: clipped, dockSurfaces: docks,
                                dockBounds: docks.map { $0.bounds.intersection(display) })
    }

    static func isVisibleDockStrip(_ bounds: CGRect, on display: CGRect) -> Bool {
        let visible = bounds.intersection(display)
        // Auto-hidden Docks may leave a one-pixel trigger strip. It isn't a
        // visible collection of icons and must never be offered as a target.
        guard !visible.isNull, visible.width >= 16, visible.height >= 16 else { return false }
        let edgeTolerance: CGFloat = 48
        let horizontal = visible.width >= 64 && visible.width >= visible.height &&
            visible.height <= display.height * 0.35 && abs(visible.maxY - display.maxY) <= edgeTolerance
        let vertical = visible.height >= 64 && visible.height >= visible.width &&
            visible.width <= display.width * 0.35 &&
            (abs(visible.minX - display.minX) <= edgeTolerance || abs(visible.maxX - display.maxX) <= edgeTolerance)
        return horizontal || vertical
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
