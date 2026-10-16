import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices
import JevAssistCore

struct ScreenSnapshot {
    let windowID: CGWindowID
    let processID: pid_t
    let bundleID: String?
    let appName: String
    let windowTitle: String
    /// Core Graphics desktop coordinates: origin is upper-left of primary screen.
    let screenBounds: CGRect
    var jpeg: Data
    let fingerprint: [UInt8]
    /// Fractional image area occupied by captured surfaces, excluding padding.
    var imageContentRect: CGRect
    let surfaceIDs: [CGWindowID]
    var surfaceBounds: [CGRect] = []
    var dockProcessID: pid_t? = nil
    var dockBounds: [CGRect] = []
    var dockFingerprint: [UInt8] = []
    var dockSurfaceIDs: [CGWindowID] = []
    var dockJPEG: Data? = nil
    var dockImageContentRect: CGRect? = nil
    /// Retained only for deferred encoding. Preparing a request consumes these
    /// exact captures rather than reading the screen a second time.
    var capturedImage: CGImage? = nil
    var capturedDockImage: CGImage? = nil

    var identity: String {
        "\(processID):\(surfaceIDs):\(surfaceBounds):\(screenBounds.origin.x):\(screenBounds.origin.y):\(screenBounds.width):\(screenBounds.height)"
    }

    func screenRect(for box: NormalizedBox) -> CGRect? {
        guard box.isValid else { return nil }
        let left = (box.left - imageContentRect.minX) / imageContentRect.width
        let right = (box.right - imageContentRect.minX) / imageContentRect.width
        let top = (box.top - imageContentRect.minY) / imageContentRect.height
        let bottom = (box.bottom - imageContentRect.minY) / imageContentRect.height
        let epsilon = 0.00000001
        guard left >= -epsilon, right <= 1 + epsilon, top >= -epsilon, bottom <= 1 + epsilon,
              right > left, bottom > top else { return nil }
        return CGRect(x: screenBounds.minX + max(0, left) * screenBounds.width,
                      y: screenBounds.minY + max(0, top) * screenBounds.height,
                      width: (min(1, right) - max(0, left)) * screenBounds.width,
                      height: (min(1, bottom) - max(0, top)) * screenBounds.height)
    }

    /// Inverse mapping for evidence about visible Dock items. Coordinates refer
    /// to the actual prepared JPEG, including its padding and Retina scaling.
    func imageRect(forScreenRect rect: CGRect) -> CGRect? {
        guard screenBounds.width > 0, screenBounds.height > 0, screenBounds.contains(rect),
              rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(x: imageContentRect.minX + (rect.minX - screenBounds.minX) / screenBounds.width * imageContentRect.width,
                      y: imageContentRect.minY + (rect.minY - screenBounds.minY) / screenBounds.height * imageContentRect.height,
                      width: rect.width / screenBounds.width * imageContentRect.width,
                      height: rect.height / screenBounds.height * imageContentRect.height)
    }

    /// A larger view of the Dock prepared from the same capture, never a new
    /// screen read. The caller must validate freshness against this original
    /// full snapshot, then map the chosen box using the returned focused frame.
    func focusedOnDock() -> ScreenSnapshot? {
        guard let jpeg = dockJPEG, let content = dockImageContentRect,
              let first = dockBounds.first else { return nil }
        let bounds = dockBounds.dropFirst().reduce(first) { $0.union($1) }
        var focused = ScreenSnapshot(windowID: dockSurfaceIDs.first ?? windowID,
            processID: processID, bundleID: bundleID, appName: appName, windowTitle: "Dock",
            screenBounds: bounds, jpeg: jpeg, fingerprint: dockFingerprint,
            imageContentRect: content, surfaceIDs: dockSurfaceIDs)
        focused.surfaceBounds = dockBounds
        focused.dockProcessID = dockProcessID
        focused.dockBounds = dockBounds
        focused.dockFingerprint = dockFingerprint
        focused.dockSurfaceIDs = dockSurfaceIDs
        return focused
    }
}

@MainActor
final class ScreenObserver {
    /// Valid only for the most recent capture attempt. A missing frame caused
    /// by read/capture failures is never reported as confirmed disappearance.
    private(set) var captureConfirmedNoSurfaces = false
    private var sceneDetector = ScreenSceneDetector()
    private var preparedSnapshot: (frame: ScreenSnapshot, at: TimeInterval)?
    /// Synthetic pipeline checks distinguish actual encoding from cache hits.
    private(set) var imageEncodingCount = 0
    private var cachedAccessibility = AccessibilityObservationCache()

    func reset() {
        sceneDetector.reset()
        preparedSnapshot = nil
        cachedAccessibility.reset()
    }

    func sameScene(_ first: ScreenSnapshot, _ second: ScreenSnapshot) -> Bool {
        ScreenSceneDetector.sameScene(sceneSample(first), sceneSample(second))
    }

    private func sceneSample(_ frame: ScreenSnapshot) -> ScreenSceneSample {
        ScreenSceneSample(identity: frame.identity, fingerprint: frame.fingerprint,
                          secondaryFingerprint: frame.dockFingerprint)
    }

    /// Tiny appearance changes never release a box. Geometry and broad content
    /// changes advance immediately; smaller real changes briefly settle.
    func observe(_ frame: ScreenSnapshot) -> (changed: Bool, stable: Bool) {
        let observation = sceneDetector.observe(sceneSample(frame), at: ProcessInfo.processInfo.systemUptime)
        if observation.changed { cachedAccessibility.reset() }
        return (observation.changed, observation.stable)
    }

    /// Fingerprint-only observations still read fresh pixels and geometry, but
    /// avoid full-image resampling and JPEG compression on the observation and
    /// response-validation paths. Call prepareForGuidance before sending one.
    func capture(app: NSRunningApplication, includeJPEG: Bool = true) -> ScreenSnapshot? {
        captureConfirmedNoSurfaces = false
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let surfaces = windows.compactMap { window -> CaptureSurface? in
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let rect = self.bounds(of: window) else { return nil }
            return CaptureSurface(id: id, processID: pid, layer: layer, bounds: rect,
                                  alpha: (window[kCGWindowAlpha as String] as? Double) ?? 1,
                                  title: window[kCGWindowName as String] as? String ?? "")
        }
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        var dockContentBounds: [CGWindowID: CGRect] = [:]
        // Missing process/display/metadata evidence is uncertainty, not absence.
        var dockReadCertain = !dockPIDs.isEmpty && !displays.isEmpty && surfaces.count == windows.count
        for surface in surfaces where dockPIDs.contains(surface.processID) &&
            surface.layer == Int(CGWindowLevelForKey(.dockWindow)) && surface.alpha > 0 {
            // The real Dock can have a full-display transparent backing window.
            // Capture only that window and inspect alpha to find its actual bar;
            // window metadata alone cannot distinguish it from a fullscreen UI.
            guard let dockWindowArray = CFArrayCreateMutable(nil, 0, nil) else { dockReadCertain = false; continue }
            CFArrayAppendValue(dockWindowArray, UnsafeRawPointer(bitPattern: Int(surface.id)))
            guard let dockImage = CGImage(windowListFromArrayScreenBounds: surface.bounds,
                windowArray: dockWindowArray, imageOption: [.boundsIgnoreFraming, .nominalResolution]) else { dockReadCertain = false; continue }
            switch DockSurfaceGeometry.assess(dockImage, windowBounds: surface.bounds, displays: displays) {
            case .visible(let visible): dockContentBounds[surface.id] = visible
            case .absent: break
            case .unavailable: dockReadCertain = false
            }
        }
        guard let selection = CaptureSurfaceSelection.select(surfaces, foregroundPID: app.processIdentifier,
            dockPIDs: dockPIDs, displays: displays, pointer: CGEvent(source: nil)?.location ?? .zero,
            dockContentBounds: dockContentBounds) else {
            // Metadata was read successfully, no app window qualified, and the
            // Dock is absent/hidden (not merely unreadable). No timer involved.
            captureConfirmedNoSurfaces = dockReadCertain
            return nil
        }
        let surfaceIDs = selection.surfaces.map(\.id)
        let bounds = selection.bounds
        // Composite only foreground app surfaces plus the verified visible Dock.
        // Gaps remain blank; other apps, wallpapers, and our overlay are excluded.
        // Core Graphics window arrays store the raw ID in each pointer slot,
        // without CF object retain/release callbacks (they aren't NSNumbers).
        guard let windowArray = CFArrayCreateMutable(nil, 0, nil) else { return nil }
        for surfaceID in surfaceIDs { CFArrayAppendValue(windowArray, UnsafeRawPointer(bitPattern: Int(surfaceID))) }
        guard let image = CGImage(windowListFromArrayScreenBounds: bounds,
                                  windowArray: windowArray,
                                  imageOption: [.boundsIgnoreFraming, .bestResolution]),
              let fingerprint = fingerprint(image) else { return nil }
        var snapshot = ScreenSnapshot(windowID: selection.anchor.id, processID: app.processIdentifier, bundleID: app.bundleIdentifier,
                              appName: app.localizedName ?? "Application", windowTitle: selection.anchor.title,
                              screenBounds: bounds, jpeg: Data(), fingerprint: fingerprint,
                              imageContentRect: ImageLayout(image).contentRect, surfaceIDs: surfaceIDs)
        snapshot.capturedImage = image
        snapshot.surfaceBounds = selection.surfaceBounds
        snapshot.dockProcessID = selection.dockSurfaces.first?.processID
        snapshot.dockBounds = selection.dockBounds
        snapshot.dockSurfaceIDs = selection.dockSurfaces.map(\.id)
        if let firstDock = selection.dockBounds.first {
            let dockArea = selection.dockBounds.dropFirst().reduce(firstDock) { $0.union($1) }
            let scaleX = CGFloat(image.width) / bounds.width, scaleY = CGFloat(image.height) / bounds.height
            let crop = CGRect(x: (dockArea.minX - bounds.minX) * scaleX,
                              y: (dockArea.minY - bounds.minY) * scaleY,
                              width: dockArea.width * scaleX, height: dockArea.height * scaleY).integral
            if let dockImage = image.cropping(to: crop) {
                snapshot.dockFingerprint = self.fingerprint(dockImage) ?? []
                snapshot.capturedDockImage = dockImage
                snapshot.dockImageContentRect = ImageLayout(dockImage).contentRect
            }
        }
        return includeJPEG ? prepareForGuidance(snapshot) : snapshot
    }

    /// Encode once when a request slot is available. The returned snapshot has
    /// the same pixels, fingerprints, geometry and identity as its observation,
    /// and drops the larger raw images so in-flight requests retain only JPEGs.
    func prepareForGuidance(_ frame: ScreenSnapshot,
                            at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ScreenSnapshot? {
        if !frame.jpeg.isEmpty { return frame }
        // Reuse only an identical observation, never the looser sameScene
        // judgment that intentionally tolerates caret/hover changes. Even exact
        // thumbnails can miss tiny content, so refresh at least every 0.5s.
        // Cache hits do not extend this deadline or affect the highlight latch.
        if let cached = preparedSnapshot, now >= cached.at, now - cached.at <= 0.5,
           cached.frame.identity == frame.identity,
           cached.frame.fingerprint == frame.fingerprint,
           cached.frame.dockFingerprint == frame.dockFingerprint,
           cached.frame.imageContentRect == frame.imageContentRect,
           cached.frame.dockImageContentRect == frame.dockImageContentRect {
            var ready = frame
            ready.jpeg = cached.frame.jpeg
            ready.imageContentRect = cached.frame.imageContentRect
            ready.dockJPEG = cached.frame.dockJPEG
            ready.dockImageContentRect = cached.frame.dockImageContentRect
            ready.capturedImage = nil
            ready.capturedDockImage = nil
            return ready
        }
        guard let image = frame.capturedImage, let prepared = prepare(image) else { return nil }
        var ready = frame
        ready.jpeg = prepared.data
        ready.imageContentRect = prepared.contentRect
        if let dockImage = frame.capturedDockImage, let dockPrepared = prepare(dockImage) {
            ready.dockJPEG = dockPrepared.data
            ready.dockImageContentRect = dockPrepared.contentRect
        }
        ready.capturedImage = nil
        ready.capturedDockImage = nil
        preparedSnapshot = (ready, now)
        return ready
    }

    private func bounds(of window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private struct ImageLayout {
        let contentWidth: Int, contentHeight: Int, canvasWidth: Int, canvasHeight: Int
        let x: Double, y: Double

        init(_ image: CGImage) {
            let width = Double(image.width), height = Double(image.height)
            let desiredScale = max(1, 280 / min(width, height))
            let scale = min(desiredScale, 1568 / max(width, height))
            contentWidth = Int((width * scale).rounded())
            contentHeight = Int((height * scale).rounded())
            canvasWidth = max(280, contentWidth)
            canvasHeight = max(280, contentHeight)
            x = Double(canvasWidth - contentWidth) / 2
            y = Double(canvasHeight - contentHeight) / 2
        }

        var contentRect: CGRect {
            CGRect(x: x / Double(canvasWidth), y: y / Double(canvasHeight),
                   width: Double(contentWidth) / Double(canvasWidth), height: Double(contentHeight) / Double(canvasHeight))
        }
    }

    func prepare(_ image: CGImage) -> (data: Data, contentRect: CGRect)? {
        let layout = ImageLayout(image)
        let canvasWidth = layout.canvasWidth, canvasHeight = layout.canvasHeight
        guard let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                      bytesPerRow: canvasWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: layout.x, y: layout.y, width: Double(layout.contentWidth), height: Double(layout.contentHeight)))
        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        imageEncodingCount += 1
        return (data as Data, layout.contentRect)
    }

    func fingerprint(_ image: CGImage) -> [UInt8]? {
        let width = 128, height = 80
        var pixels = [UInt8](repeating: 0, count: width * height)
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return succeeded ? pixels : nil
    }

    func accessibilityContext(for frame: ScreenSnapshot) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let readAt = ProcessInfo.processInfo.systemUptime
        if let cached = cachedAccessibility.value(processID: frame.processID, dockProcessID: frame.dockProcessID, at: readAt) {
            return cached.context(for: frame)
        }
        let app = AXUIElementCreateApplication(frame.processID)
        AXUIElementSetMessagingTimeout(app, 0.03)
        var focused: CFTypeRef?
        var labels = [String]()
        var visited = 0
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused {
            let window = unsafeBitCast(focused, to: AXUIElement.self)
            collectLabels(window, depth: 0, visited: &visited, deadline: Date().addingTimeInterval(0.08), into: &labels)
        }
        var dockItems = [AccessibilityObservation.DockItem]()
        if let pid = frame.dockProcessID {
            let dock = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(dock, 0.02)
            visited = 0
            collectDockItems(dock, depth: 0, visited: &visited,
                             deadline: Date().addingTimeInterval(0.06), into: &dockItems)
        }
        let observation = AccessibilityObservation(appLabels: labels, dockItems: dockItems)
        cachedAccessibility.store(observation, processID: frame.processID, dockProcessID: frame.dockProcessID, at: readAt)
        return observation.context(for: frame)
    }

    private func collectDockItems(_ element: AXUIElement, depth: Int,
                                  visited: inout Int, deadline: Date, into items: inout [AccessibilityObservation.DockItem]) {
        guard depth < 5, items.count < 100, visited < 100, Date() < deadline else { return }
        visited += 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == "AXDockItem", let rect = accessibilityRect(element) {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let title = value as? String, !title.isEmpty {
                    items.append(AccessibilityObservation.DockItem(title: String(title.prefix(80)), screenBounds: rect))
                    break
                }
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return }
        for child in elements.prefix(50) {
            collectDockItems(child, depth: depth + 1, visited: &visited, deadline: deadline, into: &items)
        }
    }

    private func accessibilityRect(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func collectLabels(_ element: AXUIElement, depth: Int, visited: inout Int, deadline: Date, into labels: inout [String]) {
        guard depth < 6, labels.count < 100, visited < 120, Date() < deadline else { return }
        visited += 1
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let label = value as? String, !label.isEmpty, !labels.contains(label) {
                labels.append(String(label.prefix(120)))
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return }
        for child in elements.prefix(30) { collectLabels(child, depth: depth + 1, visited: &visited, deadline: deadline, into: &labels) }
    }
}
