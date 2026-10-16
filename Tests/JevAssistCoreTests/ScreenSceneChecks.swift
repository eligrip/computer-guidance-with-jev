import Foundation
#if !JEV_ASSIST_STANDALONE_TESTS
@testable import JevAssistCore
#endif

enum ScreenSceneChecks {
    static func run(_ expect: (Bool, String) throws -> Void) throws {
        let blank = [UInt8](repeating: 240, count: 128 * 80)
        func painting(_ source: [UInt8], x: Range<Int>, y: Range<Int>, color: UInt8) -> [UInt8] {
            var output = source
            for row in y { for column in x { output[row * 128 + column] = color } }
            return output
        }
        func sample(_ pixels: [UInt8], identity: String = "app:window:geometry",
                    dock: [UInt8] = []) -> ScreenSceneSample {
            ScreenSceneSample(identity: identity, fingerprint: pixels, secondaryFingerprint: dock)
        }
        let original = sample(blank)
        var detector = ScreenSceneDetector()
        let initial = detector.observe(original, at: 0)
        try expect(initial.changed && initial.stable, "Initial scene establishes a baseline")
        let caret = painting(blank, x: 50..<51, y: 30..<35, color: 0)
        let counter = painting(blank, x: 50..<54, y: 30..<34, color: 0)
        let hoverBase = painting(blank, x: 30..<54, y: 30..<40, color: 100)
        let hover = painting(hoverBase, x: 30..<54, y: 30..<40, color: 160)
        try expect(ScreenSceneDetector.sameScene(original, sample(caret)), "Caret blink is fresh")
        try expect(ScreenSceneDetector.sameScene(original, sample(counter)), "Small timer digit is fresh")
        try expect(ScreenSceneDetector.sameScene(sample(hoverBase), sample(hover)), "Recoloring a control preserves its geometry")
        var noise = blank
        for row in 0..<10 { for column in 0..<16 { noise[(row * 8 + 3) * 128 + column * 8 + 3] = 100 } }
        try expect(ScreenSceneDetector.sameScene(original, sample(noise)), "Sparse pixel noise does not look like content")
        let dockIcon = painting(blank, x: 30..<42, y: 20..<50, color: 0)
        try expect(ScreenSceneDetector.sameScene(sample(blank, dock: blank), sample(blank, dock: dockIcon)),
                   "One magnified Dock icon animation does not advance the scene")

        let dialog = sample(painting(blank, x: 16..<40, y: 16..<32, color: 80))
        let pending = detector.observe(dialog, at: 1)
        try expect(!pending.changed && !pending.stable, "A local content change starts settling")
        for step in 1..<12 {
            let state = detector.observe(dialog, at: 1 + Double(step) / 100)
            try expect(!state.changed && !state.stable, "Fast sampling preserves the first settling deadline")
        }
        let settled = detector.observe(dialog, at: 1.121)
        try expect(settled.changed && settled.stable, "Local content settles even at 100Hz")
        let unchanged = detector.observe(dialog, at: 10_000)
        try expect(!unchanged.changed && unchanged.stable, "No timeout advances an unchanged scene")
        try expect(!ScreenSceneDetector.sameScene(original, dialog), "Result freshness rejects a new dialog")
        detector.reset()
        _ = detector.observe(original, at: 0)
        _ = detector.observe(dialog, at: 0.01)
        let reverted = detector.observe(original, at: 0.06)
        try expect(!reverted.changed && reverted.stable, "Transient content that returns to baseline does not clear")
        _ = detector.observe(dialog, at: 0.1)
        let dialogWithCaret = sample(painting(dialog.fingerprint, x: 90..<91, y: 30..<35, color: 0))
        let stableWithCaret = detector.observe(dialogWithCaret, at: 0.221)
        try expect(stableWithCaret.changed && stableWithCaret.stable, "Caret noise cannot restart local settling")

        let newPage = sample([UInt8](repeating: 80, count: blank.count))
        let navigation = detector.observe(newPage, at: 0.23)
        try expect(navigation.changed && navigation.stable, "Broad navigation invalidates immediately")
        let geometry = detector.observe(sample(newPage.fingerprint, identity: "moved-window"), at: 0.231)
        try expect(geometry.changed && geometry.stable, "Actual window geometry invalidates immediately")
        try expect(!ScreenSceneDetector.sameScene(original, sample(blank, identity: "other-app")), "Another foreground app rejects old results")
        try expect(!ScreenSceneDetector.sameScene(original, sample([1, 2])), "Malformed fingerprints fail closed")
        let rearrangedDock = painting(blank, x: 16..<48, y: 8..<72, color: 0)
        try expect(!ScreenSceneDetector.sameScene(sample(blank, dock: blank), sample(blank, dock: rearrangedDock)),
                   "Substantial Dock layout/content change rejects an old result")

        detector.reset()
        var latch = HighlightLatch()
        latch.beginSession()
        if detector.observe(original, at: 0).changed { latch.screenDidChange() }
        let request = latch.makeRequest()!
        let box = NormalizedBox(top: 0.1, bottom: 0.2, left: 0.1, right: 0.2)
        _ = latch.apply(GuidanceResult(box: box, confidence: 0.9, presence: 0.9), for: request)
        for index in 1...300 {
            let result = detector.observe(index.isMultiple(of: 2) ? original : sample(caret), at: Double(index) * 0.05)
            if result.changed { latch.screenDidChange() }
        }
        try expect(latch.box == box, "Repeated cursor blinking never removes the latched box")
        let oldResult = latch.makeRequest()!
        if detector.observe(newPage, at: 16).changed { latch.screenDidChange() }
        try expect(latch.box == nil, "Real navigation releases the held box promptly")
        try expect(!latch.apply(GuidanceResult(box: box, confidence: 0.9, presence: 0.9), for: oldResult),
                   "A pre-navigation request cannot restore a stale target")
    }
}
