#!/bin/bash
set -euo pipefail

if [[ "${1:-}" != "--live" ]]; then
  echo "Opt-in required: bash scripts/smoke-native.sh --live"
  echo "Uses a generated image and synthetic speech. Add --consensus for a three-call Box comparison."
  exit 2
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache" "$project_root/.build/smoke"
swiftc -parse-as-library \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root"/Sources/JevAssistCore/*.swift \
  "$project_root/scripts/smoke-native.swift" \
  -o "$project_root/.build/smoke/jev-native-smoke"
cd "$project_root"
exec "$project_root/.build/smoke/jev-native-smoke" "$@"
