#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[a-p]{32}$ ]]; then
  echo "Usage: $0 EXTENSION_ID [PATH_TO_JevAssistBridge]" >&2
  echo "Load browser-extension/ in chrome://extensions, then copy its 32-letter ID." >&2
  exit 2
fi

extension_id="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
bridge_path="${2:-$project_dir/dist/JevAssist.app/Contents/MacOS/JevAssistBridge}"
if [[ ! -x "$bridge_path" ]]; then
  echo "Bridge executable not found. Build the Mac app first: $bridge_path" >&2
  exit 1
fi

# Python serializes the absolute path instead of interpolating it into JSON.
# This registers only a user-level Chrome host; no extension is auto-installed.
python3 - "$extension_id" "$bridge_path" <<'PY'
import json
import os
from pathlib import Path
import sys

extension_id, executable = sys.argv[1:]
directory = Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
directory.mkdir(parents=True, exist_ok=True)
destination = directory / "ai.typesafe.jevassist.json"
manifest = {
    "name": "ai.typesafe.jevassist",
    "description": "Jev Assist active browser page context",
    "path": str(Path(executable).resolve()),
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
temporary = destination.with_suffix(".json.tmp")
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w") as stream:
    json.dump(manifest, stream, indent=2)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, destination)
print(f"Registered Chrome native host: {destination}")
print("Open the Jev Assist extension and choose Share during this help session.")
PY
