#!/bin/sh
# Signs CrossKit.app inside-out with the right entitlements per bundle.
# Identity: $CROSSKIT_SIGN_IDENTITY (e.g. "Developer ID Application: …"), default ad-hoc "-".
set -eu
identity="${CROSSKIT_SIGN_IDENTITY:--}"
app="${1:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
src="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
appex="$app/Contents/PlugIns/CrossKitExtension.appex"
sign() { codesign --force --timestamp=none --sign "$identity" "$@"; }
[ -d "$appex/Contents/Frameworks/XcodeKit.framework" ] && sign "$appex/Contents/Frameworks/XcodeKit.framework"
[ -d "$app/Contents/Frameworks/CrossKitCore.framework" ] && sign "$app/Contents/Frameworks/CrossKitCore.framework"
sign --entitlements "$src/Sources/CrossKitExtension/CrossKitExtension.entitlements" "$appex"
sign --entitlements "$src/Sources/CrossKitApp/CrossKit.entitlements" "$app"
echo "Signed $app with identity '$identity'"
