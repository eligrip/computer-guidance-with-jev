import AppKit

@MainActor
final class HighlightOverlay {
    private var panel: NSPanel?

    func show(coreGraphicsRect rect: CGRect) {
        // AppKit uses bottom-left coordinates relative to the primary display.
        // The primary display height (not main/active display) handles monitors
        // placed above, below, or to the left without a Retina pixel conversion.
        guard let primary = NSScreen.screens.first else { return }
        let cocoaRect = Self.cocoaRect(for: rect, primaryDisplayHeight: primary.frame.height)
        if panel == nil {
            let panel = NSPanel(contentRect: cocoaRect, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.sharingType = .none
            panel.contentView = HighlightView()
            self.panel = panel
        }
        panel?.setFrame(cocoaRect, display: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    static func cocoaRect(for rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX - 6, y: primaryDisplayHeight - rect.maxY - 6,
               width: rect.width + 12, height: rect.height + 12)
    }
}

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 5, dy: 5)
        let outer = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outer.lineWidth = 6
        outer.stroke()
        NSColor.systemTeal.setStroke()
        outer.lineWidth = 3
        outer.stroke()
        NSColor.systemTeal.withAlphaComponent(0.07).setFill()
        outer.fill()
    }
}
