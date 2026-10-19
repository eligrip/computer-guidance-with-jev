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
        let navigation = observer.observe(changed)
        expect(navigation.changed && navigation.stable, "broad navigation releases a stale target immediately")
        let settled = observer.observe(changed)
        expect(!settled.changed && settled.stable, "unchanged navigation result stays stable")
        expect(observer.observe(frame(blank, window: 2)).changed, "window switch changes scene immediately")
        observer.reset()
        _ = observer.observe(snapshot)
        var localized = blank
        for y in 16..<32 { for x in 16..<40 { localized[y * 128 + x] = 230 } }
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
        expect(otherDisplay.minX == -1200 - HighlightDrawing.overlayPadding && otherDisplay.minY == 1140 - HighlightDrawing.overlayPadding, "display above and left maps into AppKit space")
        for (width, height) in [(30, 40), (1900, 100), (4000, 2000), (500, 500)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let prepared = observer.prepare(context.makeImage()!)!
            let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            expect((280...1568).contains(image.width) && (280...1568).contains(image.height)
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
        // Observation and response validation need fresh scene evidence, not
        // two JPEG encodes. Deferred preparation must use the same image data.
        var deferred = frame(observer.fingerprint(originalImage)!)
        deferred.capturedImage = originalImage
        deferred.capturedDockImage = originalImage.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 100))
        deferred.dockBounds = [CGRect(x: 100, y: 700, width: 1000, height: 100)]
        deferred.dockSurfaceIDs = [99]
        deferred.dockFingerprint = observer.fingerprint(deferred.capturedDockImage!)!
        expect(deferred.jpeg.isEmpty && deferred.dockJPEG == nil, "unprepared observation has no encoded payload")
        let ready = observer.prepareForGuidance(deferred)!
        expect(!ready.jpeg.isEmpty && ready.dockJPEG != nil, "deferred preparation encodes scene and Dock")
        expect(ready.identity == deferred.identity && observer.sameScene(deferred, ready), "deferred encoding preserves exact observation identity and pixels")
        expect(ready.capturedImage == nil && ready.capturedDockImage == nil, "prepared requests release raw capture images")
        expect(ready.jpeg == observer.prepare(originalImage)!.data, "deferred JPEG comes from retained original capture")
        expect(ready.focusedOnDock()?.jpeg == ready.dockJPEG, "Dock view uses the prepared crop from the same capture")
        expect(observer.prepareForGuidance(ready)?.jpeg == ready.jpeg, "already prepared snapshot reuses its JPEG")
        expect(observer.prepareForGuidance(snapshot) == nil, "missing source image never becomes an empty request payload")
        // Cache evidence is exact fingerprint equality, not the more tolerant
        // meaningful-change policy. Its deadline uses an injected monotonic clock.
        let cacheObserver = ScreenObserver()
        deferred.dockImageContentRect = ready.dockImageContentRect
        let firstPrepared = cacheObserver.prepareForGuidance(deferred, at: 100)!
        let firstEncodes = cacheObserver.imageEncodingCount
        expect(firstEncodes == 2, "first prepared scene and Dock each encode once")
        let reused = cacheObserver.prepareForGuidance(deferred, at: 100.1)!
        expect(cacheObserver.imageEncodingCount == firstEncodes && reused.jpeg == firstPrepared.jpeg,
               "identical observations reuse encoded scene and Dock")
        expect(reused.capturedImage == nil && reused.capturedDockImage == nil, "cache hits release raw capture images")
        var tinyPixels = deferred.fingerprint
        tinyPixels[500] = tinyPixels[500] == 255 ? 254 : tinyPixels[500] + 1
        var tinyChange = frame(tinyPixels, content: deferred.imageContentRect)
        tinyChange.capturedImage = deferred.capturedImage
        tinyChange.capturedDockImage = deferred.capturedDockImage
        tinyChange.dockBounds = deferred.dockBounds
        tinyChange.dockSurfaceIDs = deferred.dockSurfaceIDs
        tinyChange.dockFingerprint = deferred.dockFingerprint
        tinyChange.dockImageContentRect = deferred.dockImageContentRect
        expect(cacheObserver.sameScene(deferred, tinyChange), "tiny cache fixture remains the same meaningful scene")
        _ = cacheObserver.prepareForGuidance(tinyChange, at: 100.2)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 2, "even a tolerated tiny fingerprint change invalidates JPEG reuse")
        var dockChange = tinyChange
        dockChange.dockFingerprint[500] = dockChange.dockFingerprint[500] == 255 ? 254 : dockChange.dockFingerprint[500] + 1
        _ = cacheObserver.prepareForGuidance(dockChange, at: 100.3)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 4, "Dock-only fingerprint changes invalidate JPEG reuse")
        var moved = dockChange
        moved.surfaceBounds = [CGRect(x: 101, y: 200, width: 1000, height: 600)]
        _ = cacheObserver.prepareForGuidance(moved, at: 100.4)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 6, "changed surface geometry invalidates JPEG reuse")
        _ = cacheObserver.prepareForGuidance(moved, at: 100.8)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 6, "cache hit within half a second avoids encoding")
        _ = cacheObserver.prepareForGuidance(moved, at: 100.91)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 8, "cache hits never extend the half-second refresh deadline")
        cacheObserver.reset()
        _ = cacheObserver.prepareForGuidance(moved, at: 101)
        expect(cacheObserver.imageEncodingCount == firstEncodes + 10, "reset clears prepared image cache")
        var appView = ScreenSnapshot(windowID: 1, processID: 100, bundleID: "fixture", appName: "Fixture", windowTitle: "App window",
            screenBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), jpeg: Data(), fingerprint: blank,
            imageContentRect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6), surfaceIDs: [1, 99])
        appView.dockBounds = [CGRect(x: 0, y: 900, width: 1000, height: 100)]
        appView.dockProcessID = 200
        var dockView = ScreenSnapshot(windowID: 99, processID: 100, bundleID: "fixture", appName: "Fixture", windowTitle: "Dock",
            screenBounds: CGRect(x: 0, y: 900, width: 1000, height: 100), jpeg: Data(), fingerprint: blank,
            imageContentRect: CGRect(x: 0, y: 0.25, width: 1, height: 0.5), surfaceIDs: [99])
        dockView.dockBounds = appView.dockBounds
        dockView.dockProcessID = 200
        let accessibility = AccessibilityObservation(appLabels: ["Search", "Save"], dockItems: [
            .init(title: "Mail", screenBounds: CGRect(x: 100, y: 920, width: 100, height: 40)),
            .init(title: "Other display", screenBounds: CGRect(x: 1200, y: 920, width: 100, height: 40)),
            .init(title: "Hidden item", screenBounds: CGRect(x: 100, y: 400, width: 100, height: 40))
        ])
        let fullContext = accessibility.context(for: appView)
        let dockContext = accessibility.context(for: dockView)
        expect(fullContext.contains("Mail [left 0.180, top 0.752, right 0.260, bottom 0.776]"), "shared AX observation maps full-image padding")
        expect(dockContext.contains("Mail [left 0.100, top 0.350, right 0.200, bottom 0.550]"), "shared AX observation remaps the Dock crop independently")
        expect(fullContext.contains("Search | Save") && dockContext.contains("Search | Save"), "app labels are shared across scene and Dock views")
        expect(!dockContext.contains("Other display") && !fullContext.contains("Hidden item"), "raw AX items outside visible capture remain excluded")
        expect(fullContext.contains("Window: App window") && dockContext.contains("Window: Dock"), "view metadata is rendered from the current frame")
        var accessibilityCache = AccessibilityObservationCache()
        accessibilityCache.store(accessibility, processID: 100, dockProcessID: 200, at: 10)
        expect(accessibilityCache.value(processID: 100, dockProcessID: 200, at: 10.1)?.context(for: dockView) == dockContext,
               "one raw AX read serves another image view")
        expect(accessibilityCache.value(processID: 101, dockProcessID: 200, at: 10.1) == nil,
               "AX evidence cannot cross active processes")
        expect(accessibilityCache.value(processID: 100, dockProcessID: nil, at: 10.1) == nil,
               "changed Dock process evidence requires a new AX read")
        _ = accessibilityCache.value(processID: 100, dockProcessID: 200, at: 10.9)
        expect(accessibilityCache.value(processID: 100, dockProcessID: 200, at: 11.01) == nil,
               "AX cache hits do not extend one-second freshness")
        expect(accessibilityCache.value(processID: 100, dockProcessID: 200, at: 9.9) == nil,
               "AX cache rejects reversed clock readings")
        accessibilityCache.reset()
        expect(accessibilityCache.value(processID: 100, dockProcessID: 200, at: 10.2) == nil,
               "scene or session reset discards shared AX evidence")
        reportImageProcessingPerformance(observer)
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
        expect(GuidancePace.restored(nil) == .fast && GuidancePace.restored("unknown") == .fast, "fast guidance is the default")
        expect(GuidancePace.fast.maximumConcurrentRequests == 6 && GuidancePace.balanced.maximumConcurrentRequests == 1, "guidance pace bounds concurrent requests")
        expect(GuidancePace.fast.minimumInterval == 0.02 && GuidancePace.balanced.minimumInterval == 0.25, "guidance pace uses 20ms and 250ms dispatch intervals")
        expect(GuidancePace.fast.observationInterval == 40_000_000 && GuidancePace.balanced.observationInterval == 160_000_000, "observation cadence is independent of request completion")
        let now = Date(timeIntervalSince1970: 1_000)
        let oldDispatch = now.addingTimeInterval(-1)
        for pace in GuidancePace.allCases {
            expect(!pace.canDispatch(inFlight: 0, lastDispatch: oldDispatch, retryAfter: now.addingTimeInterval(1), now: now), "retry-after blocks \(pace.rawValue) guidance")
        }
        expect(!GuidancePace.balanced.canDispatch(inFlight: 2, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now), "lowering pace does not dispatch while earlier requests run")
        expect(!GuidancePace.fast.canDispatch(inFlight: 6, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now), "fast guidance cannot exceed six requests")
        expect(GuidancePace.fast.canDispatch(inFlight: 5, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now), "fast guidance immediately fills a completed request slot")
        expect(!GuidancePace.fast.canDispatch(inFlight: 0, lastDispatch: now.addingTimeInterval(-0.02), retryAfter: .distantPast, now: now), "fast guidance honors its cadence")
        expect(!GuidancePace.balanced.canDispatch(inFlight: 0, lastDispatch: now.addingTimeInterval(-0.15), retryAfter: .distantPast, now: now), "balanced guidance honors its cadence")
        expect(BoxSampling.restored(nil) == .single && BoxSampling.restored("consensus") == .consensus, "three checks is a persistent opt-in experiment")
        expect(BoxSampling.consensus.sampleCount == 3, "consensus requests exactly three answers")
        for pace in GuidancePace.allCases {
            expect(pace.canDispatch(inFlight: 0, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now, sampling: .consensus), "consensus starts a fresh three-call group")
            let groupLimit = pace == .fast ? 2 : 1
            expect(!pace.canDispatch(inFlight: groupLimit, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now, sampling: .consensus), "consensus honors its bounded group count")
            expect(pace.canDispatch(inFlight: groupLimit - 1, lastDispatch: oldDispatch, retryAfter: .distantPast, now: now, sampling: .consensus), "consensus uses available group capacity")
            expect(!pace.canDispatch(inFlight: 0, lastDispatch: oldDispatch, retryAfter: now.addingTimeInterval(1), now: now, sampling: .consensus), "consensus honors retry-after")
        }
        SetupChecks.run { expect($0, $1) }
        checks += CaptureSurfaceChecks.run()
        checks += HighlightAppearanceChecks.run()
        checks += DockCaptureChecks.run()
        checks += SessionRecorderChecks.run()
        print("Native checks passed: \(checks)")
    }

    /// Informational measurements only: no flaky machine-speed assertion. The
    /// fixture represents a Retina window plus Dock; real screen acquisition
    /// and provider latency are deliberately excluded from these numbers.
    private static func reportImageProcessingPerformance(_ observer: ScreenObserver) {
        let width = 3024, height = 1964
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<35 {
            for column in 0..<8 {
                context.setFillColor(CGColor(gray: Double((row * 7 + column * 11) % 60) / 100 + 0.1, alpha: 1))
                context.fill(CGRect(x: 30 + column * 370, y: 20 + row * 54, width: 240 + row % 80, height: 12))
            }
        }
        let image = context.makeImage()!
        let dock = image.cropping(to: CGRect(x: 300, y: 1800, width: 2400, height: 140))!
        func fingerprintPair() { _ = observer.fingerprint(image); _ = observer.fingerprint(dock) }
        func encodedPair() { fingerprintPair(); _ = observer.prepare(image); _ = observer.prepare(dock) }
        fingerprintPair(); encodedPair()
        func millisecondsPerIteration(_ operation: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<12 { autoreleasepool { operation() } }
            return (ProcessInfo.processInfo.systemUptime - start) * 1000 / 12
        }
        let validation = millisecondsPerIteration(fingerprintPair)
        let encodesBefore = observer.imageEncodingCount
        let encoded = millisecondsPerIteration(encodedPair)
        let successfulEncodes = observer.imageEncodingCount - encodesBefore
        print(String(format: "Synthetic image processing, 3024×1964 + Dock: fingerprints %.2f ms; fingerprints + JPEGs %.2f ms (%d forced JPEG encodes, screen acquisition excluded)", validation, encoded, successfulEncodes))
    }
}
