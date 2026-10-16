#!/bin/bash
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
"$PROJECT_ROOT/scripts/restart.sh" "$@"
RESULT=$?
if [[ "$RESULT" -ne 0 && -t 0 ]]; then
    printf '\nPress Return to close this window.\n'
    read -r _
fi
exit "$RESULT"
