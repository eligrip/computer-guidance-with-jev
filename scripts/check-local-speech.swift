import Foundation
import Speech

// Synthetic audio only: no microphone, screen capture, Jev calls, or user text.
// Run outside restrictive process sandboxes so Apple's speech XPC service can
// be reached. This test never opts into online recognition.
guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
    fputs("FAIL: English (US) speech recognizer unavailable.\n", stderr)
    exit(1)
}
guard recognizer.supportsOnDeviceRecognition else {
    fputs("FAIL: English (US) local model unavailable. Enable macOS Keyboard → Dictation, select English (US), then retry after assets download.\n", stderr)
    exit(1)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jev-speech-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: directory) }
let audio = directory.appendingPathComponent("synthetic.aiff")
let synthesizer = Process()
synthesizer.executableURL = URL(fileURLWithPath: "/usr/bin/say")
synthesizer.arguments = ["-v", "Samantha", "-o", audio.path,
                         "Please open the email attachment from Jane."]
try synthesizer.run()
synthesizer.waitUntilExit()
guard synthesizer.terminationStatus == 0 else {
    fputs("FAIL: Could not synthesize the test fixture.\n", stderr)
    exit(1)
}

let request = SFSpeechURLRecognitionRequest(url: audio)
request.requiresOnDeviceRecognition = true
request.shouldReportPartialResults = true
var completed = false
var passed = false
var partialCount = 0
let task = recognizer.recognitionTask(with: request) { result, error in
    if let result {
        partialCount += 1
        if result.isFinal {
            let text = result.bestTranscription.formattedString
            passed = ["email", "attachment", "jane"].allSatisfy { text.lowercased().contains($0) }
            print("Synthetic result: \(text)")
            print("Recognition updates: \(partialCount)")
            completed = true
        }
    }
    if let error, !completed {
        let error = error as NSError
        fputs("FAIL: Local speech error \(error.domain) / \(error.code).\n", stderr)
        completed = true
    }
}
let deadline = Date().addingTimeInterval(30)
while !completed && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
task.cancel()
guard completed, passed else {
    fputs(completed ? "FAIL: Synthetic phrase did not match.\n" : "FAIL: Local speech timed out.\n", stderr)
    exit(1)
}
print("PASS: English (US) transcribed with requiresOnDeviceRecognition=true. No microphone used.")
