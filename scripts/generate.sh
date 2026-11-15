#!/bin/sh
# Regenerates CrossKit.xcodeproj from project.yml using the XcodeGen version pinned in .mise.toml.
set -eu
cd "$(dirname "$0")/.."
if command -v mise >/dev/null 2>&1; then
  exec mise exec xcodegen@2.46.0 -- xcodegen generate --spec project.yml
fi
exec xcodegen generate --spec project.yml
