#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
"$flutter_bin" pub get
"$flutter_bin" analyze
"$flutter_bin" test
swift test
