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
    let jpeg: Data
    let fingerprint: [UInt8]
    /// Fractional image area occupied by captured surfaces, excluding padding.
    let imageContentRect: CGRect
    let surfaceIDs: [CGWindowID]
    var surfaceBounds: [CGRect] = []
    var dockProcessID: pid_t? = nil
    var dockBounds: [CGRect] = []
    var dockFingerprint: [UInt8] = []

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
}

@MainActor
final class ScreenObserver {
    private var baseline: ScreenSnapshot?
    private var pending: ScreenSnapshot?
    private var pendingSince = Date.distantPast
    private var cachedAccessibility = ""
    private var accessibilityReadAt = Date.distantPast
    private var accessibilityIdentity = ""

    func reset() {
        baseline = nil; pending = nil
        accessibilityIdentity = ""
        cachedAccessibility = ""
        accessibilityReadAt = .distantPast
    }

    func sameScene(_ first: ScreenSnapshot, _ second: ScreenSnapshot) -> Bool {
        first.identity == second.identity && !pixelsDiffer(first, second)
    }

    private func pixelsDiffer(_ first: ScreenSnapshot, _ second: ScreenSnapshot) -> Bool {
        isDifferent(first.fingerprint, second.fingerprint) ||
        (!(first.dockFingerprint.isEmpty && second.dockFingerprint.isEmpty) &&
         isDifferent(first.dockFingerprint, second.dockFingerprint))
    }

    /// Small pixel changes (caret, pointer and tiny hover animations) don't count.
    /// A changed page must remain stable across samples before releasing a box.
    func observe(_ frame: ScreenSnapshot) -> (changed: Bool, stable: Bool) {
        guard let baseline else { self.baseline = frame; return (true, true) }
        if baseline.identity != frame.identity {
            self.baseline = frame
            pending = nil
            accessibilityIdentity = ""
            return (true, true)
        }
        guard pixelsDiffer(baseline, frame) else {
            pending = nil
            return (false, true)
        }
        if let pending, !pixelsDiffer(pending, frame), Date().timeIntervalSince(pendingSince) >= 0.12 {
            self.baseline = frame
            self.pending = nil
            accessibilityIdentity = ""
            return (true, true)
        }
        pending = frame
        pendingSince = Date()
        return (false, false)
    }

    private func isDifferent(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var changed = 0
        var totalDifference = 0
        var tileChanges = [Int](repeating: 0, count: 160)
        for i in a.indices {
            let difference = abs(Int(a[i]) - Int(b[i]))
            if difference > 24 {
                changed += 1
                tileChanges[(i / 128 / 8) * 16 + (i % 128 / 8)] += 1
            }
            totalDifference += difference
        }
        let globalChange = Double(changed) / Double(a.count) > 0.008 && Double(totalDifference) / Double(a.count) > 0.8
        let localChange = changed >= 30 && (tileChanges.max() ?? 0) >= 22
        return globalChange || localChange
    }

    func capture(app: NSRunningApplication) -> ScreenSnapshot? {
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
        guard let selection = CaptureSurfaceSelection.select(surfaces, foregroundPID: app.processIdentifier,
            dockPIDs: dockPIDs, displays: displays, pointer: CGEvent(source: nil)?.location ?? .zero) else { return nil }
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
              let prepared = prepare(image), let fingerprint = fingerprint(image) else { return nil }
        var snapshot = ScreenSnapshot(windowID: selection.anchor.id, processID: app.processIdentifier, bundleID: app.bundleIdentifier,
                              appName: app.localizedName ?? "Application", windowTitle: selection.anchor.title,
                              screenBounds: bounds, jpeg: prepared.data, fingerprint: fingerprint,
                              imageContentRect: prepared.contentRect, surfaceIDs: surfaceIDs)
        snapshot.surfaceBounds = selection.surfaceBounds
        snapshot.dockProcessID = selection.dockSurfaces.first?.processID
        snapshot.dockBounds = selection.dockBounds
        if let firstDock = selection.dockBounds.first {
            let dockArea = selection.dockBounds.dropFirst().reduce(firstDock) { $0.union($1) }
            let scaleX = CGFloat(image.width) / bounds.width, scaleY = CGFloat(image.height) / bounds.height
            let crop = CGRect(x: (dockArea.minX - bounds.minX) * scaleX,
                              y: (dockArea.minY - bounds.minY) * scaleY,
                              width: dockArea.width * scaleX, height: dockArea.height * scaleY).integral
            if let dockImage = image.cropping(to: crop), let pixels = self.fingerprint(dockImage) { snapshot.dockFingerprint = pixels }
        }
        return snapshot
    }

    private func bounds(of window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    func prepare(_ image: CGImage) -> (data: Data, contentRect: CGRect)? {
        let width = Double(image.width), height = Double(image.height)
        let desiredScale = max(1, 280 / min(width, height))
        let scale = min(desiredScale, 1568 / max(width, height))
        let contentWidth = Int((width * scale).rounded()), contentHeight = Int((height * scale).rounded())
        let canvasWidth = max(280, contentWidth), canvasHeight = max(280, contentHeight)
        guard let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                      bytesPerRow: canvasWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        let x = Double(canvasWidth - contentWidth) / 2, y = Double(canvasHeight - contentHeight) / 2
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: y, width: Double(contentWidth), height: Double(contentHeight)))
        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, CGRect(x: x / Double(canvasWidth), y: y / Double(canvasHeight),
                                    width: Double(contentWidth) / Double(canvasWidth), height: Double(contentHeight) / Double(canvasHeight)))
    }

    private func fingerprint(_ image: CGImage) -> [UInt8]? {
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
        guard accessibilityIdentity != frame.identity || Date().timeIntervalSince(accessibilityReadAt) > 1 else { return cachedAccessibility }
        accessibilityIdentity = frame.identity
        accessibilityReadAt = Date()
        cachedAccessibility = ""
        let app = AXUIElementCreateApplication(frame.processID)
        AXUIElementSetMessagingTimeout(app, 0.03)
        var focused: CFTypeRef?
        var labels = [String]()
        var visited = 0
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused {
            let window = unsafeBitCast(focused, to: AXUIElement.self)
            collectLabels(window, depth: 0, visited: &visited, deadline: Date().addingTimeInterval(0.08), into: &labels)
        }
        var dockLabels = [String]()
        if let pid = frame.dockProcessID {
            let dock = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(dock, 0.02)
            visited = 0
            collectDockLabels(dock, frame: frame, depth: 0, visited: &visited,
                              deadline: Date().addingTimeInterval(0.06), into: &dockLabels)
        }
        let context = "Active app: \(frame.appName). Window: \(frame.windowTitle). " +
            "Visible Dock items (labels and normalized screenshot rectangles, evidence only): " + dockLabels.joined(separator: " | ") +
            ". App accessibility labels: " + labels.joined(separator: " | ")
        cachedAccessibility = String(context.prefix(5_000))
        return cachedAccessibility
    }

    private func collectDockLabels(_ element: AXUIElement, frame: ScreenSnapshot, depth: Int,
                                   visited: inout Int, deadline: Date, into labels: inout [String]) {
        guard depth < 5, labels.count < 40, visited < 100, Date() < deadline else { return }
        visited += 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == "AXDockItem", let rect = accessibilityRect(element),
           frame.dockBounds.contains(where: { $0.intersects(rect) }), let normalized = frame.imageRect(forScreenRect: rect) {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let title = value as? String, !title.isEmpty {
                    labels.append(String(title.prefix(80)) + String(format: " [left %.3f, top %.3f, right %.3f, bottom %.3f]",
                        Double(normalized.minX), Double(normalized.minY), Double(normalized.maxX), Double(normalized.maxY)))
                    break
                }
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return }
        for child in elements.prefix(50) {
            collectDockLabels(child, frame: frame, depth: depth + 1, visited: &visited, deadline: deadline, into: &labels)
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
