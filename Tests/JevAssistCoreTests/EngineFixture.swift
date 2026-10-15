import Foundation
#if !JEV_ASSIST_STANDALONE_TESTS
@testable import JevAssistCore
#endif

/// Deterministic local subprocess; no network or real credentials.
final class EngineFixture {
    private let directory: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jev-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fixture.py")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func transport(timeout: TimeInterval = 3, mode: String = "normal") -> RustEngineTransport {
        RustEngineTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                            arguments: [script.path, mode], requestTimeout: timeout)
    }

    func client(timeout: TimeInterval = 3, mode: String = "normal") -> JevClient {
        JevClient(apiKey: "fixture-not-a-real-key", transport: transport(timeout: timeout, mode: mode))
    }

    static func input(_ text: String) -> GuidanceInput {
        GuidanceInput(transcript: text, goal: nil, notes: "fixture notes", browserContext: "fixture browser",
                      accessibilityContext: nil, imageJPEG: Data([0xff, 0xd8, 0xff, 0xd9]))
    }

    private static let source = #"""
import base64, json, os, sys, threading, time
lock = threading.Lock()
if sys.argv[1] == "exit-before-read":
    os._exit(3)

def respond(request):
    text = request["input"]["transcript"]
    if text == "crash":
        os._exit(7)
    if text == "hang":
        time.sleep(10)
    if text.startswith("slow:"):
        time.sleep(0.15)
    if text == "malformed":
        with lock:
            print("not-json", flush=True)
        return
    if text == "rate-limit":
        reply = {"id":request["id"], "ok":False,
                 "error":{"message":"private upstream content must not be exposed", "retry_after":2.5, "status":429}}
    elif request["op"] == "goal":
        goal = None if text == "none" else (str(os.getpid()) if text == "pid" else text)
        reply = {"id":request["id"], "ok":True, "result":{"goal":goal}}
    else:
        assert request["api_key"] == "fixture-not-a-real-key"
        assert request["model"] == "jev-1.14.0"
        assert request["minimum_presence"] == 0.65
        assert request["minimum_confidence"] == 0.25
        assert request["input"]["notes"] == "fixture notes"
        assert request["input"]["browser_context"] == "fixture browser"
        assert request["input"]["accessibility_context"] is None
        assert base64.b64decode(request["input"]["image_jpeg_base64"]).startswith(b"\xff\xd8\xff")
        box = None if text == "absent" else {"top":0.1, "bottom":0.2, "left":0.3, "right":0.4}
        if text == "invalid-box":
            box["top"] = 0.9
        reply = {"id":request["id"], "ok":True,
                 "result":{"box":box, "confidence":0.9, "presence":0.1 if text == "absent" else 0.95}}
    encoded = json.dumps(reply)
    with lock:
        if text == "fragment":
            half = len(encoded) // 2
            sys.stdout.write(encoded[:half]); sys.stdout.flush()
            time.sleep(0.03)
            sys.stdout.write(encoded[half:] + "\n"); sys.stdout.flush()
        else:
            print(encoded, flush=True)

workers = []
for line in sys.stdin:
    worker = threading.Thread(target=respond, args=(json.loads(line),), daemon=True)
    worker.start()
    workers.append(worker)
for worker in workers:
    worker.join()
"""#
}
