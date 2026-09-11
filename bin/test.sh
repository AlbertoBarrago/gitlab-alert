#!/bin/bash
# Data layer and app lifecycle tests: no signing, no GUI, no Xcode.
set -e
cd "$(dirname "$0")/.."
swift test --package-path GitLabKit "$@"

swift test "$@"
