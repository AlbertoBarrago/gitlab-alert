#!/bin/bash
# Rebuild, reinstall and stream the logs in real time.
# Uso: bash bin/run-with-logs.sh

set -e
cd "$(dirname "$0")/.."

bash bin/make-app.sh

pkill -x GitLabAlert 2>/dev/null || true
sleep 0.5

open /Applications/GitLabAlert.app

echo ""
echo "=== GitLab Alert live logs (Ctrl+C to stop) ==="
echo "Token and Authorization headers are never logged."
echo ""

/usr/bin/log stream \
  --predicate 'subsystem == "com.alBz.GitLabAlert"' \
  --level debug \
  --style compact
