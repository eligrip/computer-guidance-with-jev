import AppKit
import ImageIO
import JevAssistCore

/// Deterministic capture-processing checks. No microphone, screen permission,
/// user content, network, or persisted settings are used.
@MainActor
enum NativeChecks {
    static func run() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        func frame(_ pixels: [UInt8], window: UInt32 = 1, content: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ScreenSnapshot {
            ScreenSnapshot(windowID: window, processID: 100, bundleID: "fixture", appName: "Fixture", windowTitle: "Fixture",
                           screenBounds: CGRect(x: 100, y: 200, width: 1000, height: 600), jpeg: Data(),
                           fingerprint: pixels, imageContentRect: content, surfaceIDs: [window])
        }
        let blank = [UInt8](repeating: 100, count: 128 * 80)
        let snapshot = frame(blank)
        let observer = ScreenObserver()
        let first = observer.observe(snapshot)
        expect(first.changed && first.stable, "first frame establishes a stable scene")
        var caret = blank
        caret[500] = 240
        let caretResult = observer.observe(frame(caret))
        expect(!caretResult.changed && caretResult.stable, "caret blink preserves scene")
        let changed = frame([UInt8](repeating: 200, count: 128 * 80))
        let pending = observer.observe(changed)
        expect(!pending.changed && !pending.stable, "screen change waits for settled frame")
        Thread.sleep(forTimeInterval: 0.14)
        let settled = observer.observe(changed)
        expect(settled.changed && settled.stable, "settled change releases old scene")
        expect(observer.observe(frame(blank, window: 2)).changed, "window switch changes scene immediately")
        observer.reset()
        _ = observer.observe(snapshot)
        var localized = blank
        for y in 16..<22 { for x in 16..<22 { localized[y * 128 + x] = 230 } }
        expect(!observer.observe(frame(localized)).stable, "small local dialog change is detected")
        expect(!observer.sameScene(snapshot, changed), "stale request screenshot rejected")
        expect(observer.sameScene(snapshot, frame(caret)), "tiny change does not reject request")
        let box = NormalizedBox(top: 0.2, bottom: 0.6, left: 0.1, right: 0.3)
        let rect = snapshot.screenRect(for: box)!
        expect(abs(rect.minX - 200) < 0.001 && abs(rect.minY - 320) < 0.001, "normalized box maps to screen points")
        expect(abs(rect.width - 200) < 0.001 && abs(rect.height - 240) < 0.001, "mapping is independent of Retina pixels")
        let padded = frame(blank, content: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
        let paddedBox = NormalizedBox(top: 0.2, bottom: 0.8, left: 0.1, right: 0.9)
        expect(padded.screenRect(for: paddedBox)?.width == 1000, "padding is removed from coordinates")
        expect(padded.screenRect(for: NormalizedBox(top: 0, bottom: 0.1, left: 0, right: 0.1)) == nil, "padding targets rejected")
        let otherDisplay = HighlightOverlay.cocoaRect(for: CGRect(x: -1200, y: -300, width: 100, height: 60), primaryDisplayHeight: 900)
        expect(otherDisplay.minX == -1206 && otherDisplay.minY == 1134, "display above and left maps into AppKit space")
        for (width, height) in [(30, 40), (1900, 100), (4000, 2000), (500, 500)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let prepared = observer.prepare(context.makeImage()!)!
            let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            expect((256...1568).contains(image.width) && (256...1568).contains(image.height)
                   && image.width * image.height >= 78_400, "JPEG size limits for \(width)×\(height)")
        }
        // An asymmetric fixture catches vertical flips introduced by image
        // preparation, which coordinate-only tests would otherwise miss.
        let colors = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        colors.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        colors.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        colors.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        colors.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        let originalImage = colors.makeImage()!
        let encodedImage = observer.prepare(originalImage)!
        let decodedSource = CGImageSourceCreateWithData(encodedImage.data as CFData, nil)!
        let decodedImage = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)!
        let originalPixels = NSBitmapImageRep(cgImage: originalImage)
        let decodedPixels = NSBitmapImageRep(cgImage: decodedImage)
        for y in [20, 380] {
            let before = originalPixels.colorAt(x: 20, y: y)!.usingColorSpace(.deviceRGB)!
            let after = decodedPixels.colorAt(x: 20, y: y)!.usingColorSpace(.deviceRGB)!
            expect(abs(before.redComponent - after.redComponent) < 0.08
                   && abs(before.blueComponent - after.blueComponent) < 0.08, "JPEG preserves image orientation at row \(y)")
        }
        let languages = ["en-US", "en-GB", "fr-FR", "zh-Hant-TW", "zh-Hans-CN"]
        expect(SpeechLanguage.resolve(saved: "en_GB", preferred: ["fr-FR"], available: languages) == "en-GB", "saved speech language overrides system preference")
        expect(SpeechLanguage.resolve(saved: "unsupported", preferred: ["fr-FR"], available: languages) == "fr-FR", "unsupported saved language falls back to preferred speech language")
        expect(SpeechLanguage.resolve(saved: nil, preferred: ["en-AU"], available: languages).hasPrefix("en-"), "speech language matches a supported regional variant")
        expect(SpeechLanguage.resolve(saved: nil, preferred: ["zh-Hant-HK"], available: languages) == "zh-Hant-TW", "speech language preserves the requested script")
        expect(SpeechRecognitionMode.restored(nil) == .onDeviceOnly && SpeechRecognitionMode.restored("invalid") == .onDeviceOnly, "online audio never becomes the implicit default")
        expect(SpeechRecognitionMode.restored("appleAutomatic") == .appleAutomatic, "explicit online recognition choice persists")
        let localSpeech = SpeechConfiguration(languageID: "en-US", mode: .onDeviceOnly)
        let automaticSpeech = SpeechConfiguration(languageID: "en-US", mode: .appleAutomatic)
        expect(localSpeech.requiresOnDeviceRecognition && !automaticSpeech.requiresOnDeviceRecognition, "recognition request honors chosen audio mode")
        expect(localSpeech.blocker(recognizerExists: true, onDeviceSupported: false, serviceAvailable: true) != nil, "local-only mode remains local when assets are missing")
        expect(automaticSpeech.blocker(recognizerExists: true, onDeviceSupported: false, serviceAvailable: true) == nil, "available Apple recognition is usable without local assets after opt-in")
        expect(automaticSpeech.blocker(recognizerExists: false, onDeviceSupported: false, serviceAvailable: true) != nil, "unsupported speech language is reported separately")
        expect(automaticSpeech.blocker(recognizerExists: true, onDeviceSupported: false, serviceAvailable: false) != nil, "service outage is reported separately from local asset availability")
        print("Native checks passed: \(checks)")
    }
}
