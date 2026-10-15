#!/usr/bin/env python3
"""Save a TypeSafe API key locally without echoing it or using shell history."""

import getpass
import os
from pathlib import Path
import re
import sys


def main() -> None:
    destination = Path(__file__).resolve().parents[1] / ".env.local"
    if destination.exists() or destination.is_symlink():
        raise SystemExit(".env.local already exists; leaving it unchanged.")
    if not sys.stdin.isatty():
        raise SystemExit("Run this script in an interactive terminal.")

    print("Jev / TypeSafe API key setup")
    print("Input is hidden. The key will be saved only to this project's .env.local.")
    try:
        key = getpass.getpass("Paste your Jev API key, then press Enter: ").strip()
    except (EOFError, KeyboardInterrupt):
        raise SystemExit("\nCancelled; no key saved.") from None
    if not re.fullmatch(r"[A-Za-z0-9._~+/=-]+", key):
        raise SystemExit("No valid Bearer token entered; no key saved.")

    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(f"TYPESAFE_API_KEY={key}\n")
    print("Saved TYPESAFE_API_KEY to .env.local with owner-only permissions (600).")
    print("The key has not been sent to TypeSafe or tested yet.")


if __name__ == "__main__":
    main()
