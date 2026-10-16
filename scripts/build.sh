#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
case "${1:-}" in
    "") APP_DIR="$PROJECT_ROOT/dist/JevAssist.app" ;;
    --stage) APP_DIR="$PROJECT_ROOT/.build/next/JevAssist.app" ;;
    *) printf 'Usage: scripts/build.sh [--stage]\n' >&2; exit 1 ;;
esac
mkdir -p "$PROJECT_ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
cargo build --manifest-path "$PROJECT_ROOT/engine/Cargo.toml" --release --locked
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/JevAssist" "$APP_DIR/Contents/MacOS/JevAssist"
cp "$BIN_DIR/JevAssistBridge" "$APP_DIR/Contents/MacOS/JevAssistBridge"
cp "$PROJECT_ROOT/engine/target/release/jev-assist-engine" "$APP_DIR/Contents/MacOS/jev-assist-engine"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/user_notes.example.md" "$APP_DIR/Contents/Resources/user_notes.example.md"
if [[ -n "${JEV_ASSIST_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_ARGS=(--force --sign "$JEV_ASSIST_SIGNING_IDENTITY")
elif [[ -f "$PROJECT_ROOT/.local-signing/identity" ]]; then
    python3 "$PROJECT_ROOT/scripts/local-signing.py" sign "$APP_DIR"
    printf 'Built %s\n' "$APP_DIR"
    exit 0
else
    SIGNING_ARGS=(--force --sign -)
    printf 'Ad-hoc build: macOS may forget permissions after changes. For local testing, run python3 scripts/local-signing.py setup once.\n' >&2
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR/Contents/MacOS/jev-assist-engine"
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR/Contents/MacOS/JevAssistBridge"
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
