#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache" "$project_root/.build/regression"
swiftc -parse-as-library -D JEV_ASSIST_STANDALONE_TESTS \
  -module-cache-path "$project_root/.build/module-cache" \
  "$project_root"/Sources/JevAssistCore/*.swift \
  "$project_root/Tests/JevAssistCoreTests/EngineFixture.swift" \
  "$project_root/Tests/JevAssistCoreTests/RegressionHarness.swift" \
  -o "$project_root/.build/regression/core-regressions"
"$project_root/.build/regression/core-regressions"
