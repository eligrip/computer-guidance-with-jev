#!/usr/bin/env python3
"""Restart this checkout's exact app, optionally promoting a verified staged build.

Uses AppKit through the Objective-C runtime: no compilation, AppleScript,
Automation access, credentials, process-name matching, or force termination.
"""
from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

IDENTIFIER = "ai.typesafe.jevassist"


class RestartError(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class Signature:
    identifier: str
    requirement: str
    cdhash: str


def run(arguments: list[str]) -> str:
    completed = subprocess.run(arguments, capture_output=True, text=True)
    if completed.returncode:
        raise RestartError(f"{Path(arguments[0]).name} could not complete; the app was not accepted as a valid signed build.")
    return completed.stdout + completed.stderr


def signature(app: Path) -> Signature:
    if app.is_symlink() or not (app / "Contents/MacOS/JevAssist").is_file():
        raise RestartError(f"Not a regular Jev Assist app bundle: {app}")
    try:
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise RestartError("The app bundle metadata could not be read.") from error
    if info.get("CFBundleIdentifier") != IDENTIFIER or info.get("CFBundleExecutable") != "JevAssist":
        raise RestartError("The app bundle has an unexpected identity.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    details = run(["/usr/bin/codesign", "--display", "--verbose=4", "--requirements", "-", str(app)])
    fields = dict(line.split("=", 1) for line in details.splitlines() if "=" in line)
    requirement = next((line.partition("designated => ")[2].strip() for line in details.splitlines()
                        if "designated => " in line), "")
    if fields.get("Identifier") != IDENTIFIER or not fields.get("CDHash") or not requirement:
        raise RestartError("The signed app identity could not be established.")
    return Signature(IDENTIFIER, requirement, fields["CDHash"])


def compatible(installed: Signature, staged: Signature) -> None:
    if installed.identifier != staged.identifier or installed.requirement != staged.requirement:
        raise RestartError("The staged app uses a different signing identity. Rebuild it with the same local signing identity before restarting; the current app has been left alone.")


def packaged_at_ns(app: Path) -> int:
    # build.sh copies the main executable without preserving its modification
    # time, then signs it. ditto preserves that time when installing a stage.
    # The enclosing directory's time can remain unchanged across normal builds.
    return (app / "Contents/MacOS/JevAssist").stat().st_mtime_ns


class AppKitWorkspace:
    """Small, typed Objective-C bridge over macOS's native app lifecycle API."""
    def __init__(self) -> None:
        ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")
        self.objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
        self.objc.objc_getClass.argtypes = [ctypes.c_char_p]
        self.objc.objc_getClass.restype = ctypes.c_void_p
        self.objc.sel_registerName.argtypes = [ctypes.c_char_p]
        self.objc.sel_registerName.restype = ctypes.c_void_p
        self.send_address = ctypes.cast(self.objc.objc_msgSend, ctypes.c_void_p).value
        self.pool = self.send(self.send(self.cls("NSAutoreleasePool"), "alloc"), "init")

    def cls(self, name: str) -> int:
        return self.objc.objc_getClass(name.encode())

    def send(self, obj: int, selector: str, restype=ctypes.c_void_p, arguments=()) -> object:
        types = [kind for kind, _ in arguments]
        values = [value for _, value in arguments]
        method = ctypes.CFUNCTYPE(restype, ctypes.c_void_p, ctypes.c_void_p, *types)(self.send_address)
        return method(obj, self.objc.sel_registerName(selector.encode()), *values)

    def string(self, value: str) -> int:
        return self.send(self.cls("NSString"), "stringWithUTF8String:", arguments=[(ctypes.c_char_p, value.encode())])

    def path(self, obj: int, selector: str) -> Path | None:
        url = self.send(obj, selector)
        if not url:
            return None
        text = self.send(self.send(url, "path"), "UTF8String", ctypes.c_char_p)
        return Path(os.fsdecode(text)).resolve() if text else None

    def applications(self, app: Path) -> list[int]:
        apps = self.send(self.cls("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:",
                         arguments=[(ctypes.c_void_p, self.string(IDENTIFIER))])
        count = self.send(apps, "count", ctypes.c_ulong)
        matches = []
        for index in range(count):
            candidate = self.send(apps, "objectAtIndex:", arguments=[(ctypes.c_ulong, index)])
            if (self.path(candidate, "bundleURL") == app.resolve()
                    and self.path(candidate, "executableURL") == (app / "Contents/MacOS/JevAssist").resolve()
                    and not self.send(candidate, "isTerminated", ctypes.c_bool)):
                matches.append(candidate)
        return matches

    def pump(self) -> None:
        deadline = self.send(self.cls("NSDate"), "dateWithTimeIntervalSinceNow:", arguments=[(ctypes.c_double, 0.1)])
        loop = self.send(self.cls("NSRunLoop"), "currentRunLoop")
        self.send(loop, "runUntilDate:", None, [(ctypes.c_void_p, deadline)])

    def terminate(self, app: Path) -> None:
        originals = self.applications(app)
        for running in originals:
            self.send(running, "terminate", ctypes.c_bool)
        deadline = time.monotonic() + 12
        while any(not self.send(running, "isTerminated", ctypes.c_bool) for running in originals):
            if time.monotonic() >= deadline:
                raise RestartError("Jev Assist did not quit. Close its open dialog, stop the help session, and try Restart again. No app files were replaced.")
            self.pump()
        if self.applications(app):
            raise RestartError("Another Jev Assist instance opened during restart. Close it and try again. No app files were replaced.")

    def launch(self, app: Path, root: Path) -> None:
        completed = subprocess.run(["/usr/bin/open", "-n", str(app), "--args", "--project-root", str(root)],
                                   capture_output=True, text=True)
        if completed.returncode:
            raise RestartError("macOS could not reopen Jev Assist.")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.pump()
            if self.applications(app):
                return
        raise RestartError("Jev Assist did not finish opening.")

    def close(self) -> None:
        if self.pool:
            self.send(self.pool, "drain", None)
            self.pool = None


def copy_bundle(source: Path, destination: Path) -> None:
    run(["/usr/bin/ditto", str(source), str(destination)])


def restart(root: Path, *, dry_run: bool = False, read_signature=signature,
            workspace=None, copy=copy_bundle, replace=os.replace) -> str:
    installed = root / "dist/JevAssist.app"
    staged = root / ".build/next/JevAssist.app"
    old = read_signature(installed) if installed.exists() else None
    stage_not_newer = (old is not None and staged.exists()
                       and packaged_at_ns(staged) <= packaged_at_ns(installed))
    new = read_signature(staged) if staged.exists() and not stage_not_newer else None
    if old is None and new is None:
        if dry_run:
            return "No installed app or staged app. Restart would build a staged app once, then install it."
        subprocess.run([str(root / "scripts/build.sh"), "--stage"], check=True)
        new = read_signature(staged)
    if old is not None and new is not None:
        compatible(old, new)
    promote = new is not None and (old is None or old.cdhash != new.cdhash)
    ignored_stage_note = " The staged build is not newer, so it was ignored." if stage_not_newer else ""
    if dry_run:
        return ("Would install the verified staged app and restart this checkout’s Jev Assist." if promote
                else "Would restart this checkout’s installed Jev Assist; no build or update needed." + ignored_stage_note)

    (root / "dist").mkdir(parents=True, exist_ok=True)
    backup_directory = root / ".build/restart-backups"
    backup_directory.mkdir(parents=True, exist_ok=True)
    prepared = root / "dist" / f".JevAssist.install-{uuid.uuid4().hex}.app"
    backup = None
    promoted = False
    stopped = False
    owns_workspace = workspace is None
    try:
        if promote:
            copy(staged, prepared)
            copied = read_signature(prepared)
            if copied != new:
                raise RestartError("The staged app changed while it was copied. Wait for the build to finish and restart again.")
            if old:
                compatible(old, copied)
        if workspace is None:
            workspace = AppKitWorkspace()
        workspace.terminate(installed)
        stopped = True
        if promote:
            if old:
                stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
                backup = backup_directory / f"JevAssist-{stamp}-{uuid.uuid4().hex[:8]}.app"
                replace(installed, backup)
            replace(prepared, installed)
            promoted = True
            if read_signature(installed) != new:
                raise RestartError("The installed update did not match its verified staged copy.")
        workspace.launch(installed, root)
        return "Installed the staged update and reopened Jev Assist." if promote else "Reopened Jev Assist." + ignored_stage_note
    except Exception as error:
        if stopped and backup and backup.exists():
            try:
                if promoted:
                    workspace.terminate(installed)
                    failed = backup_directory / f"JevAssist-failed-{uuid.uuid4().hex[:8]}.app"
                    replace(installed, failed)
                replace(backup, installed)
                workspace.launch(installed, root)
            except Exception as recovery:
                raise RestartError(f"Restart failed and automatic recovery could not complete. The previous app is preserved at {backup}. {recovery}") from error
            raise RestartError("The update could not be installed or opened. The previous app was restored and reopened.") from error
        if stopped and old and not promoted:
            try:
                workspace.launch(installed, root)
            except Exception:
                pass
        raise
    finally:
        if prepared.exists():
            shutil.rmtree(prepared)
        if owns_workspace and workspace is not None:
            workspace.close()


def self_test() -> None:
    """Synthetic bundle/filesystem tests; AppKit and codesign are never loaded."""
    class FakeWorkspace:
        def __init__(self, fail_first_launch=False):
            self.calls = []
            self.fail_first_launch = fail_first_launch
        def terminate(self, app):
            self.calls.append(("stop", app))
        def launch(self, app, root):
            self.calls.append(("open", app))
            if self.fail_first_launch:
                self.fail_first_launch = False
                raise RestartError("synthetic launch failure")
    def inspect(app):
        value = (app / "fixture").read_text()
        return Signature(IDENTIFIER, "different" if value == "wrong-signer" else "stable-signer", value)
    def fixture(root, path, value, packaged_at):
        app = root / path
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/JevAssist"
        executable.write_text("synthetic executable")
        os.utime(executable, ns=(packaged_at, packaged_at))
        (app / "fixture").write_text(value)
        return app
    with tempfile.TemporaryDirectory(prefix="jev restart synthetic ") as directory:
        root = Path(directory)
        installed = fixture(root, "dist/JevAssist.app", "old", 1_000_000_000)
        staged = fixture(root, ".build/next/JevAssist.app", "new", 2_000_000_000)
        workspace = FakeWorkspace()
        assert "Would install" in restart(root, dry_run=True, read_signature=inspect, workspace=workspace)
        assert not workspace.calls and inspect(installed).cdhash == "old"
        (staged / "fixture").write_text("wrong-signer")
        try:
            restart(root, read_signature=inspect, workspace=workspace, copy=shutil.copytree)
            raise AssertionError("wrong signer accepted")
        except RestartError:
            assert not workspace.calls and inspect(installed).cdhash == "old"
        (staged / "fixture").write_text("new")
        failing = FakeWorkspace(fail_first_launch=True)
        try:
            restart(root, read_signature=inspect, workspace=failing, copy=shutil.copytree)
            raise AssertionError("failed launch accepted")
        except RestartError:
            assert inspect(installed).cdhash == "old"
            assert failing.calls[-1] == ("open", installed)
        workspace = FakeWorkspace()
        restart(root, read_signature=inspect, workspace=workspace, copy=shutil.copytree)
        assert inspect(installed).cdhash == "new"
        assert workspace.calls == [("stop", installed), ("open", installed)]
        assert list((root / ".build/restart-backups").glob("JevAssist-*.app"))
        assert "no build or update" in restart(root, dry_run=True, read_signature=inspect)
        assert packaged_at_ns(installed) == packaged_at_ns(staged)
        # A subsequent normal build is newer than the stage left on disk.
        (installed / "fixture").write_text("newest-normal-build")
        os.utime(installed / "Contents/MacOS/JevAssist", ns=(3_000_000_000, 3_000_000_000))
        # Directory timestamps do not establish build order, even if touched.
        os.utime(staged, ns=(4_000_000_000, 4_000_000_000))
        workspace = FakeWorkspace()
        def no_copy(*_):
            raise AssertionError("stale stage was copied")
        result = restart(root, read_signature=inspect, workspace=workspace, copy=no_copy)
        assert "not newer" in result and inspect(installed).cdhash == "newest-normal-build"
        assert workspace.calls == [("stop", installed), ("open", installed)]
        # Equal times are ambiguous: retain the installed build even if hashes differ.
        os.utime(staged / "Contents/MacOS/JevAssist", ns=(3_000_000_000, 3_000_000_000))
        assert "not newer" in restart(root, dry_run=True, read_signature=inspect)
    print("Restart checks passed: dry-run, exact-path handoff, signing mismatch, rollback, update, stale/equal stages, and paths with spaces.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Inspect signed builds without stopping, copying, building, or opening an app")
    parser.add_argument("--self-test", action="store_true", help="Run synthetic checks without touching a real app")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    root = Path(__file__).resolve().parent.parent
    if args.dry_run:
        print(restart(root, dry_run=True))
        return 0
    lock_directory = root / ".build"
    lock_directory.mkdir(exist_ok=True)
    with (lock_directory / "restart.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RestartError("A restart is already in progress. Wait for it to finish.") from error
        print(restart(root))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RestartError, OSError, subprocess.SubprocessError) as error:
        print(f"Restart: {error}", file=sys.stderr)
        raise SystemExit(1)
