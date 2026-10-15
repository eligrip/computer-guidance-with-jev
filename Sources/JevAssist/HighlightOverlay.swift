import AppKit

@MainActor
final class HighlightOverlay {
    private var panel: NSPanel?
    var style: HighlightStyle = .softOutline {
        didSet {
            (panel?.contentView as? HighlightView)?.style = style
            panel?.contentView?.needsDisplay = true
        }
    }

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
            let view = HighlightView()
            view.style = style
            panel.contentView = view
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
    var style = HighlightStyle.softOutline
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        HighlightDrawing.draw(style: style, target: bounds.insetBy(dx: 4, dy: 4))
    }
}
