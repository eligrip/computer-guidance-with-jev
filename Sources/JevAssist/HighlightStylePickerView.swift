import AppKit
import SwiftUI

struct HighlightStylePickerView: View {
    @ObservedObject var session: SessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How should we point?").font(.system(size: 24, weight: .semibold))
            Text(reduceMotion
                ? "Choose the steady highlight that is easiest for you to see."
                : "Choose the highlight that is easiest for you to see. New guidance gives one brief pulse, then stays steady.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            ForEach(HighlightStyle.allCases) { style in
                Button {
                    session.setHighlightStyle(style)
                } label: {
                    HStack(spacing: 18) {
                        HighlightSample(style: style).frame(width: 128, height: 76)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(style.title).font(.system(size: 17, weight: .semibold))
                            Text(style.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: session.highlightStyle == style ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(session.highlightStyle == style ? .teal : .secondary)
                    }
                    .padding(12)
                    .background(session.highlightStyle == style ? Color.teal.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(session.highlightStyle == style ? Color.teal.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityValue(session.highlightStyle == style ? "Selected" : "Not selected")
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing).keyboardShortcut(.defaultAction)
        }
        .padding(28).frame(width: 500)
    }
}

private struct HighlightSample: NSViewRepresentable {
    let style: HighlightStyle
    func makeNSView(context: Context) -> HighlightSampleView { HighlightSampleView() }
    func updateNSView(_ view: HighlightSampleView, context: Context) {
        view.style = style
        view.needsDisplay = true
    }
}

private final class HighlightSampleView: NSView {
    var style = HighlightStyle.corners
    override func draw(_ dirtyRect: NSRect) {
        let button = CGRect(x: (bounds.width - 90) / 2, y: (bounds.height - 30) / 2, width: 90, height: 30)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).stroke()
        let text: NSString = "Download"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2), withAttributes: attributes)
        HighlightDrawing.draw(style: style, target: HighlightDrawing.visualTarget(for: button))
    }
}
