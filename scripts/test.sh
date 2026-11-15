#!/bin/sh
# Builds everything and runs unit + e2e tests (e2e tests skip languages whose server is not installed).
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project CrossKit.xcodeproj -scheme CrossKit -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- test "$@"
