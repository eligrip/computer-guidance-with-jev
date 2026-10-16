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
        (panel?.contentView as? HighlightView)?.beginArrival()
    }

    func hide() {
        (panel?.contentView as? HighlightView)?.endArrival()
        panel?.orderOut(nil)
    }

    static func cocoaRect(for rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        let padding = HighlightDrawing.overlayPadding
        return CGRect(x: rect.minX - padding, y: primaryDisplayHeight - rect.maxY - padding,
                      width: rect.width + 2 * padding, height: rect.height + 2 * padding)
    }
}

@MainActor
private final class HighlightView: NSView {
    var style = HighlightStyle.softOutline
    private var arrivalTask: Task<Void, Never>?
    private var arrivalElapsed: TimeInterval?

    func beginArrival() {
        endArrival()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        arrivalElapsed = 0
        needsDisplay = true
        let start = ProcessInfo.processInfo.systemUptime
        arrivalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      elapsed < HighlightArrivalCue.duration else {
                    self.arrivalElapsed = nil
                    self.needsDisplay = true
                    return
                }
                self.arrivalElapsed = elapsed
                self.needsDisplay = true
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func endArrival() {
        arrivalTask?.cancel()
        arrivalTask = nil
        arrivalElapsed = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = HighlightDrawing.overlayPadding - HighlightDrawing.targetOutset
        let target = bounds.insetBy(dx: inset, dy: inset)
        if let elapsed = arrivalElapsed {
            HighlightDrawing.drawArrival(target: target, elapsed: elapsed,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        HighlightDrawing.draw(style: style, target: target)
    }
}
