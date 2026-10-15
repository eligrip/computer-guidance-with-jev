#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_ROOT/dist/JevAssist.app"
if [[ ! -x "$APP_DIR/Contents/MacOS/JevAssist" ]]; then
    "$PROJECT_ROOT/scripts/build.sh"
fi
# Pass only a directory, never the key, to the app. The app imports .env.local.
cd "$PROJECT_ROOT"
/usr/bin/open "$APP_DIR" --args --project-root "$PROJECT_ROOT"
