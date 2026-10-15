"""Exercise interrupted signing without touching any real keychain or certificate."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts/local-signing.py"
CHILD = r'''
import importlib.util, json, signal, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("signing", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2])
module.ROOT = root
module.DIRECTORY = root / "signing"
module.KEYCHAIN = module.DIRECTORY / "fake.keychain"
module.IDENTITY = module.DIRECTORY / "identity"
module.keychain_access = lambda: None
def fake_run(arguments):
    if arguments[:4] == ["/usr/bin/security", "list-keychains", "-d", "user"]:
        state = root / "search-list.json"
        if len(arguments) > 4:
            state.write_text(json.dumps(arguments[5:]))
            return ""
        return "\n".join(json.dumps(path) for path in json.loads(state.read_text()))
    if arguments[0] == "/usr/bin/codesign":
        (root / "signing-started").touch()
        signal.pause()
    raise RuntimeError("Unexpected external operation")
module.run = fake_run
module.sign_app(root / "dist/JevAssist.app")
'''


class InterruptedSigningTests(unittest.TestCase):
    def test_termination_restores_search_list_and_preserves_unrelated_changes(self):
        for termination in [signal.SIGTERM, signal.SIGHUP]:
            with self.subTest(signal=termination), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "signing").mkdir()
                (root / "signing/identity").write_text("A" * 40)
                state = root / "search-list.json"
                original = ["/synthetic/login.keychain", "/synthetic/other.keychain"]
                state.write_text(json.dumps(original))
                child = subprocess.Popen([sys.executable, "-c", CHILD, str(HELPER), str(root)],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (root / "signing-started").exists():
                        if child.poll() is not None:
                            stdout, stderr = child.communicate()
                            self.fail("Synthetic signing failed: " + stdout + stderr)
                        if time.monotonic() > deadline:
                            self.fail("Synthetic signing did not start")
                        time.sleep(0.01)
                    # An unrelated app can change this list during a build.
                    during = json.loads(state.read_text())
                    self.assertIn(str(root / "signing/fake.keychain"), during)
                    state.write_text(json.dumps(during + ["/synthetic/new.keychain"]))
                    child.send_signal(termination)
                    stdout, stderr = child.communicate(timeout=5)
                    self.assertEqual(child.returncode, 128 + termination, stdout + stderr)
                    self.assertEqual(json.loads(state.read_text()), original + ["/synthetic/new.keychain"])
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate()


if __name__ == "__main__":
    unittest.main()
