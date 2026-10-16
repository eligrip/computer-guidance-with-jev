#!/usr/bin/env python3
"""Keep this Mac's development app identity stable across rebuilds.

Creates an isolated, password-protected local keychain. No system certificate
trust, login keychain, TCC permissions, or default keychain is modified. The
password goes directly to Security.framework, never into process arguments.
Use Apple Development / Developer ID signing for distribution instead.
"""
import ctypes
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / ".local-signing"
KEYCHAIN = DIRECTORY / "development.keychain-db"
PASSWORD = DIRECTORY / "keychain-password"
IDENTITY = DIRECTORY / "identity"


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        # Commands never contain passwords/private-key bytes; don't echo output
        # from credential-handling tools on failure.
        detail = result.stderr.strip() if arguments[:2] == ["/usr/bin/security", "import"] else ""
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({result.returncode}) {detail}")
    return result.stdout


def keychain_access(create=False):
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    core.CFRelease.argtypes = [ctypes.c_void_p]
    reference = ctypes.c_void_p()
    password = PASSWORD.read_bytes()
    buffer = ctypes.create_string_buffer(password)
    if create:
        function = security.SecKeychainCreate
        function.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool,
                             ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        status = function(os.fsencode(KEYCHAIN), len(password), buffer, False, None, ctypes.byref(reference))
    else:
        function = security.SecKeychainOpen
        function.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        status = function(os.fsencode(KEYCHAIN), ctypes.byref(reference))
    if status:
        raise RuntimeError(f"Local signing keychain could not be opened ({status})")
    try:
        unlock = security.SecKeychainUnlock
        unlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
        status = unlock(reference, len(password), buffer, True)
        if status:
            raise RuntimeError(f"Local signing keychain could not be unlocked ({status})")
    finally:
        core.CFRelease(reference)


def setup():
    os.umask(0o077)
    DIRECTORY.mkdir(mode=0o700, exist_ok=True)
    if IDENTITY.exists():
        if not re.fullmatch(r"[A-F0-9]{40}\n?", IDENTITY.read_text()):
            raise RuntimeError("Invalid local signing identity file")
        keychain_access()
        print("Existing local development identity is ready.")
        return
    if KEYCHAIN.exists() and PASSWORD.exists():
        keychain_access()
        if run(["/usr/bin/security", "find-certificate", "-a", str(KEYCHAIN)]).strip():
            raise RuntimeError("Incomplete signing setup contains a certificate; inspect before retrying")
    elif KEYCHAIN.exists() or PASSWORD.exists():
        raise RuntimeError("Incomplete local signing setup; preserve existing files and inspect before retrying")
    else:
        with PASSWORD.open("xb") as destination:
            destination.write(secrets.token_bytes(48).hex().encode("ascii"))
        os.chmod(PASSWORD, 0o600)
        keychain_access(create=True)
    # The owner-only temporary directory is removed immediately after importing
    # a non-extractable private key into the password-protected keychain.
    with tempfile.TemporaryDirectory(prefix="identity-", dir=DIRECTORY) as temporary:
        directory = Path(temporary)
        config = directory / "openssl.cnf"
        config.write_text("""[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = Jev Assist Local Development
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        key, certificate = [directory / name for name in ["key.pem", "certificate.pem"]]
        run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-x509", "-sha256", "-nodes",
             "-days", "3650", "-config", str(config), "-keyout", str(key), "-out", str(certificate)])
        traditional_key = directory / "key.rsa"
        run(["/usr/bin/openssl", "rsa", "-in", str(key), "-out", str(traditional_key)])
        run(["/usr/bin/security", "import", str(traditional_key), "-k", str(KEYCHAIN), "-t", "priv", "-f", "openssl",
             "-x", "-T", "/usr/bin/codesign"])
        run(["/usr/bin/security", "import", str(certificate), "-k", str(KEYCHAIN), "-t", "cert"])
        fingerprint = run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1"])
        identity = fingerprint.strip().split("=", 1)[-1].replace(":", "").upper()
        if not re.fullmatch(r"[A-F0-9]{40}", identity):
            raise RuntimeError("Could not determine the signing certificate fingerprint")
        IDENTITY.write_text(identity + "\n")
    os.chmod(KEYCHAIN, 0o600)
    print("Local development identity created. Future builds will reuse it.")


@contextmanager
def cleanup_on_termination():
    def interrupted(number, _frame):
        raise SystemExit(128 + number)

    previous = {number: signal.signal(number, interrupted) for number in [signal.SIGTERM, signal.SIGHUP]}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def sign_app(app):
    """Temporarily expose the certificate chain to codesign, then restore the list."""
    identity = IDENTITY.read_text().strip()
    if not re.fullmatch(r"[A-F0-9]{40}", identity):
        raise RuntimeError("Invalid local signing identity file")
    app = Path(app).resolve()
    if app not in [ROOT / "dist/JevAssist.app", ROOT / ".build/next/JevAssist.app"]:
        raise RuntimeError("Local signing is limited to this project's built app")
    with (DIRECTORY / "build.lock").open("a") as lock, cleanup_on_termination():
        fcntl.flock(lock, fcntl.LOCK_EX)
        keychain_access()
        original = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        added = str(KEYCHAIN) not in original
        try:
            # --keychain locates the identity, but codesign still requires the
            # certificate chain on the search list. This does not trust it.
            if added:
                run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original, str(KEYCHAIN)])
            for path in [app / "Contents/MacOS/jev-assist-engine", app / "Contents/MacOS/JevAssistBridge", app]:
                run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(KEYCHAIN),
                     "--timestamp=none", str(path)])
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        finally:
            if added:
                current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
                # Preserve unrelated search-list changes made during the build.
                run(["/usr/bin/security", "list-keychains", "-d", "user", "-s",
                     *[path for path in current if path != str(KEYCHAIN)]])


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["setup"]:
            setup()
        elif sys.argv[1:] == ["unlock"]:
            keychain_access()
        elif len(sys.argv) == 3 and sys.argv[1] == "sign":
            sign_app(sys.argv[2])
        else:
            raise RuntimeError("Usage: python3 scripts/local-signing.py setup|unlock|sign dist/JevAssist.app")
    except Exception as error:
        print(f"Local signing: {error}", file=sys.stderr)
        sys.exit(1)
