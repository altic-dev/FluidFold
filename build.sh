#!/bin/bash
# Dev build: signs with xcconfig/LocalSigning.xcconfig, installs to /Applications, launches.
set -euo pipefail
cd "$(dirname "$0")"
APP=FluidFold
BUILD_NUMBER="$(( 900000 + $(git rev-list --count HEAD) ))"   # above any release build so Sparkle never "downgrades" a dev build

[ -f xcconfig/LocalSigning.xcconfig ] || { echo "Copy xcconfig/LocalSigning.example.xcconfig to xcconfig/LocalSigning.xcconfig"; exit 1; }
[ -n "${DEVELOPER_DIR:-}" ] || export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"
xcodegen generate --quiet
source scripts/ensure_codesign_keychain.sh
SIGNING_IDENTITY="Apple Development" ensure_codesign_keychain

xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Release -destination platform=macOS \
    -derivedDataPath build/DerivedData -xcconfig xcconfig/LocalSigning.xcconfig \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

killall $APP 2>/dev/null || true
rm -rf /Applications/$APP.app
ditto build/DerivedData/Build/Products/Release/$APP.app /Applications/$APP.app
open /Applications/$APP.app
