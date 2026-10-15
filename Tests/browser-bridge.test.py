#!/usr/bin/env python3
"""Exercise the real native host over framed stdio without touching browser profiles."""
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]


def context():
    return {
        "type": "context", "schemaVersion": 1, "sharing": True,
        "capturedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "browser": "chrome", "browserBundleID": "com.google.Chrome",
        "sessionID": str(uuid.uuid4()), "sequence": 1, "tabID": 1, "windowID": 2,
        "reason": "test",
        "page": {
            "url": "https://example.test/mail?search=Jane", "title": "Mail ✓",
            "scope": "loaded-top-frame", "untrusted": True,
            "loadedText": "A loaded message from Jane", "textTruncated": False,
            "controlsTruncated": False, "limitations": "Loaded top frame only",
            "controls": [{"id": "control-0", "tag": "button", "role": "button", "label": "Download",
                          "rect": {"x": 10, "y": 20, "width": 30, "height": 40},
                          "visible": True, "inViewport": True, "disabled": False}],
        },
        "viewport": {"width": 1000, "height": 800, "scrollX": 0, "scrollY": 20, "devicePixelRatio": 2},
    }


class BrowserBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="jev-bridge-build-")
        cls.executable = Path(os.environ.get("JEV_ASSIST_BRIDGE_TEST_BINARY", Path(cls.build.name) / "JevAssistBridge"))
        if not os.environ.get("JEV_ASSIST_BRIDGE_TEST_BINARY"):
            subprocess.run(["swiftc", "-module-cache-path", str(Path(cls.build.name) / "module-cache"),
                            str(ROOT / "Sources/JevAssistBridge/main.swift"), "-o", str(cls.executable)], check=True, timeout=180)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.support = tempfile.TemporaryDirectory(prefix="jev-bridge-support-")
        self.path = Path(self.support.name) / "browser-context.json"
        self.process = self.launch()

    def launch(self):
        return subprocess.Popen([str(self.executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env={**os.environ, "JEV_ASSIST_SUPPORT_DIR": self.support.name})

    def tearDown(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        self.support.cleanup()

    def read_exact(self, size, process=None):
        process = process or self.process
        data = b""
        while len(data) < size:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            self.assertTrue(ready, "Bridge reply timed out")
            chunk = os.read(process.stdout.fileno(), size - len(data))
            self.assertTrue(chunk, "Bridge closed before a complete framed reply")
            data += chunk
        return data

    def response(self, process=None):
        size, = struct.unpack("<I", self.read_exact(4, process))
        self.assertLess(size, 1024)
        return json.loads(self.read_exact(size, process))

    def send(self, payload, process=None):
        process = process or self.process
        body = json.dumps(payload, ensure_ascii=False).encode()
        process.stdin.write(struct.pack("<I", len(body)) + body)
        process.stdin.flush()
        return self.response(process)

    def test_context_round_trip_permissions_and_stop_cleanup(self):
        payload = context()
        payload["unexpectedSecret"] = "must not be persisted"
        payload["page"]["unexpectedSecret"] = "must not be persisted"
        self.assertTrue(self.send(payload)["ok"])
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["page"]["title"], "Mail ✓")
        self.assertEqual(saved["page"]["url"], payload["page"]["url"])
        self.assertIn("receivedAt", saved)
        self.assertIn("bridgeConnectionID", saved)
        self.assertNotIn("unexpectedSecret", saved)
        self.assertNotIn("unexpectedSecret", saved["page"])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.send({"type": "stop"})["ok"])
        self.process.wait(timeout=5)
        self.assertFalse(self.path.exists())

    def test_clear_keeps_connection_usable(self):
        self.assertTrue(self.send(context())["ok"])
        self.assertTrue(self.send({"type": "clear"})["ok"])
        self.assertFalse(self.path.exists())
        self.assertTrue(self.send(context())["ok"])
        self.assertTrue(self.path.exists())

    def test_eof_removes_context(self):
        self.assertTrue(self.send(context())["ok"])
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.assertFalse(self.path.exists())

    def test_invalid_json_clears_previous_context_and_recovers(self):
        self.assertTrue(self.send(context())["ok"])
        self.process.stdin.write(struct.pack("<I", 1) + b"{")
        self.process.stdin.flush()
        self.assertFalse(self.response()["ok"])
        self.assertFalse(self.path.exists())
        self.assertTrue(self.send(context())["ok"])

    def test_oversize_frame_exits_without_waiting_for_body(self):
        self.assertTrue(self.send(context())["ok"])
        self.process.stdin.write(struct.pack("<I", 240 * 1024 + 1))
        self.process.stdin.flush()
        self.assertEqual(self.response()["error"], "invalid_frame")
        self.process.wait(timeout=5)
        self.assertFalse(self.path.exists())

    def test_truncated_frame_cleans_up(self):
        self.assertTrue(self.send(context())["ok"])
        self.process.stdin.write(struct.pack("<I", 10) + b"{\"a\"")
        self.process.stdin.close()
        self.assertEqual(self.response()["error"], "invalid_frame")
        self.process.wait(timeout=5)
        self.assertFalse(self.path.exists())

    def test_stale_capture_and_untrusted_flag_are_validated(self):
        payload = context()
        payload["capturedAt"] = (datetime.now(timezone.utc) - timedelta(seconds=60)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.assertFalse(self.send(payload)["ok"])
        payload = context()
        payload["page"]["untrusted"] = False
        self.assertFalse(self.send(payload)["ok"])
        self.assertFalse(self.path.exists())

    def test_non_web_url_and_excessive_text_rejected(self):
        payload = context()
        payload["page"]["url"] = "file:///private/file"
        self.assertFalse(self.send(payload)["ok"])
        payload = context()
        payload["page"]["loadedText"] = "x" * 24_001
        self.assertFalse(self.send(payload)["ok"])

    def test_old_connection_does_not_remove_newer_context(self):
        self.assertTrue(self.send(context())["ok"])
        second = self.launch()
        try:
            latest = context()
            latest["page"]["title"] = "New profile"
            self.assertTrue(self.send(latest, second)["ok"])
            self.assertTrue(self.send({"type": "stop"})["ok"])
            self.process.wait(timeout=5)
            self.assertEqual(json.loads(self.path.read_text())["page"]["title"], "New profile")
            self.assertTrue(self.send({"type": "stop"}, second)["ok"])
            second.wait(timeout=5)
            self.assertFalse(self.path.exists())
        finally:
            if second.poll() is None:
                second.stdin.close()
                second.wait(timeout=5)
            if not second.stdin.closed:
                second.stdin.close()
            second.stdout.close()
            second.stderr.close()


if __name__ == "__main__":
    unittest.main()
