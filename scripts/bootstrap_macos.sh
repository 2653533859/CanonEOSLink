#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
if ! command -v "$flutter_bin" >/dev/null 2>&1; then
  echo '未找到 Flutter。请安装 Flutter 3.47+，或设置 FLUTTER_BIN 为 flutter 可执行文件路径。' >&2
  exit 1
fi
xcodebuild -version
"$flutter_bin" --version
"$flutter_bin" pub get
"$flutter_bin" build ios --config-only --no-codesign
printf '\n初始化完成：在 Xcode 打开 ios/Runner.xcworkspace，配置签名后运行。\n'
