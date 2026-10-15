import AppKit
import JevAssistCore

/// Synthetic geometry and scene checks; never enumerate or record real windows.
@MainActor
enum CaptureSurfaceChecks {
    static func run() -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        func surface(_ id: UInt32, pid: pid_t = 10, layer: Int = 0,
                     rect: CGRect, alpha: Double = 1) -> CaptureSurface {
            CaptureSurface(id: id, processID: pid, layer: layer, bounds: rect, alpha: alpha, title: "Synthetic")
        }
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let main = surface(1, rect: CGRect(x: 100, y: 100, width: 900, height: 600))
        let dock = surface(2, pid: 20, layer: dockLayer, rect: CGRect(x: 300, y: 820, width: 800, height: 80))
        let popup = surface(3, layer: 101, rect: CGRect(x: 700, y: 180, width: 200, height: 200))
        let foreign = surface(4, pid: 30, rect: display)
        let wallpaper = surface(5, pid: 20, layer: -2147483623, rect: display)
        let fullScreenDockSurface = surface(6, pid: 20, layer: dockLayer, rect: display)
        let hiddenDock = surface(7, pid: 20, layer: dockLayer, rect: CGRect(x: 300, y: 899, width: 800, height: 80))
        let wrongOwner = surface(8, pid: 30, layer: dockLayer, rect: dock.bounds)
        let backgroundSameApp = surface(9, rect: CGRect(x: 50, y: 50, width: 400, height: 400))
        let surfaces = [popup, dock, foreign, main, backgroundSameApp, wallpaper, fullScreenDockSurface, hiddenDock, wrongOwner]
        let selection = CaptureSurfaceSelection.select(surfaces, foregroundPID: 10, dockPIDs: [20], displays: [display], pointer: .zero)!
        expect(selection.surfaces.map(\.id) == [3, 2, 1], "capture includes foreground popover and Dock in window-server order")
        expect(selection.bounds == CGRect(x: 100, y: 100, width: 1000, height: 800), "capture bounds include visible bottom Dock")
        expect(selection.dockSurfaces.map(\.id) == [2], "wallpaper, fullscreen, hidden, and foreign Dock-like surfaces excluded")
        let desktop = CaptureSurfaceSelection.select(surfaces, foregroundPID: 99, dockPIDs: [20], displays: [display], pointer: .zero)!
        expect(desktop.surfaces.map(\.id) == [2] && desktop.bounds == dock.bounds, "visible Dock remains usable with no foreground window")
        expect(CaptureSurfaceSelection.select([hiddenDock, wallpaper, foreign], foregroundPID: 99,
            dockPIDs: [20], displays: [display], pointer: .zero) == nil, "hidden Dock does not capture other apps as a fallback")
        expect(CaptureSurfaceSelection.select([dock], foregroundPID: 99, dockPIDs: [], displays: [display], pointer: .zero) == nil,
               "Dock process identity must be verified")

        let leftDisplay = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let leftMain = surface(11, rect: CGRect(x: -1300, y: -100, width: 900, height: 600))
        let leftDock = surface(12, pid: 20, layer: dockLayer, rect: CGRect(x: -1440, y: 10, width: 80, height: 500))
        let second = CaptureSurfaceSelection.select([dock, leftDock, leftMain], foregroundPID: 10,
            dockPIDs: [20], displays: [display, leftDisplay], pointer: CGPoint(x: 100, y: 100))!
        expect(second.dockSurfaces.map(\.id) == [12], "foreground window chooses relevant display rather than mouse display")
        expect(second.bounds.minX == -1440 && second.bounds.minY == -100, "negative desktop coordinates remain unchanged")
        let desktopSecond = CaptureSurfaceSelection.select([dock, leftDock], foregroundPID: 99,
            dockPIDs: [20], displays: [display, leftDisplay], pointer: CGPoint(x: -300, y: 100))!
        expect(desktopSecond.dockSurfaces.map(\.id) == [12], "desktop-only capture follows the display under the pointer")
        let rightDock = CGRect(x: 1360, y: 100, width: 80, height: 500)
        expect(CaptureSurfaceSelection.isVisibleDockStrip(rightDock, on: display), "right-side Dock is supported")
        expect(CaptureSurfaceSelection.isVisibleDockStrip(CGRect(x: 650, y: 820, width: 120, height: 80), on: display),
               "compact Dock with only a few icons is supported")
        expect(!CaptureSurfaceSelection.isVisibleDockStrip(CGRect(x: 400, y: 300, width: 600, height: 80), on: display),
               "floating Dock-process content is excluded")

        let blank = [UInt8](repeating: 100, count: 128 * 80)
        var snapshot = ScreenSnapshot(windowID: 1, processID: 10, bundleID: "fixture", appName: "Fixture", windowTitle: "Synthetic",
            screenBounds: selection.bounds, jpeg: Data(), fingerprint: blank,
            imageContentRect: CGRect(x: 0, y: 0, width: 1, height: 1), surfaceIDs: selection.surfaces.map(\.id))
        snapshot.surfaceBounds = selection.surfaceBounds
        snapshot.dockBounds = selection.dockBounds
        snapshot.dockFingerprint = blank
        let observer = ScreenObserver()
        _ = observer.observe(snapshot)
        var dockLayout = snapshot
        dockLayout.surfaceBounds[1] = CGRect(x: 310, y: 820, width: 780, height: 80)
        expect(!observer.sameScene(snapshot, dockLayout), "Dock geometry invalidates old answers even if composite bounds stay unchanged")
        expect(observer.observe(dockLayout).changed, "Dock layout change releases the old scene")
        observer.reset()
        _ = observer.observe(snapshot)
        var dockPixels = snapshot
        for y in 16..<22 { for x in 16..<22 { dockPixels.dockFingerprint[y * 128 + x] = 230 } }
        expect(!observer.sameScene(snapshot, dockPixels), "localized Dock icon change is detected independently of whole-screen reduction")
        expect(!observer.observe(dockPixels).stable, "Dock animation waits for settling before replacing a highlight")
        Thread.sleep(forTimeInterval: 0.14)
        expect(observer.observe(dockPixels).changed, "settled Dock icon change advances the scene")
        var removedDock = ScreenSnapshot(windowID: 1, processID: 10, bundleID: "fixture", appName: "Fixture", windowTitle: "Synthetic",
            screenBounds: selection.bounds, jpeg: Data(), fingerprint: blank,
            imageContentRect: CGRect(x: 0, y: 0, width: 1, height: 1), surfaceIDs: [1])
        removedDock.surfaceBounds = [main.bounds]
        removedDock.dockBounds = []
        removedDock.dockFingerprint = []
        expect(!observer.sameScene(snapshot, removedDock), "Dock disappearance invalidates previous results")

        var dockOnly = ScreenSnapshot(windowID: 2, processID: 99, bundleID: "fixture", appName: "Fixture", windowTitle: "Dock",
            screenBounds: dock.bounds, jpeg: Data(), fingerprint: blank,
            imageContentRect: CGRect(x: 0, y: 0.35, width: 1, height: 0.3), surfaceIDs: [2])
        dockOnly.dockBounds = [dock.bounds]
        let icon = CGRect(x: 340, y: 830, width: 50, height: 50)
        let normalized = dockOnly.imageRect(forScreenRect: icon)!
        let roundTrip = dockOnly.screenRect(for: NormalizedBox(top: normalized.minY, bottom: normalized.maxY,
                                                              left: normalized.minX, right: normalized.maxX))!
        expect(abs(roundTrip.minX - icon.minX) < 0.001 && abs(roundTrip.minY - icon.minY) < 0.001 &&
               abs(roundTrip.width - icon.width) < 0.001 && abs(roundTrip.height - icon.height) < 0.001,
               "Dock item evidence round-trips through padded screenshot coordinates")
        expect(dockOnly.imageRect(forScreenRect: CGRect(x: 0, y: 0, width: 50, height: 50)) == nil,
               "off-capture accessibility items are excluded")
        return checks
    }
}
