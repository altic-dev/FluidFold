#!/bin/bash
# Release: universal build, Developer ID, notarize, DMG, Sparkle appcast, GitHub release.
# Needs release.env (copy release.env.example) and a notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")"
APP=FluidFold
REPO=altic-dev/FluidFold
source release.env
: "${DEVELOPER_ID:?}" "${TEAM_ID:?}" "${NOTARIZATION_PROFILE:?}"

VERSION="$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT=build/release
ARCHIVE=$OUT/$APP.xcarchive
APP_PATH=$OUT/export/$APP.app
DMG=$OUT/$APP-$VERSION.dmg

[ -n "${DEVELOPER_DIR:-}" ] || export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"
xcodegen generate --quiet
source scripts/ensure_codesign_keychain.sh
SIGNING_IDENTITY="Developer ID Application" ensure_codesign_keychain
rm -rf "$OUT"; mkdir -p "$OUT"

echo "▸ archive $APP $VERSION ($BUILD_NUMBER)"
xcodebuild archive -project $APP.xcodeproj -scheme $APP -configuration Release \
    -destination generic/platform=macOS -archivePath "$ARCHIVE" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

cat > $OUT/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath $OUT/export -exportOptionsPlist $OUT/export.plist \
    2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"

echo "▸ notarize app"
ditto -c -k --keepParent "$APP_PATH" $OUT/$APP.zip
xcrun notarytool submit $OUT/$APP.zip --keychain-profile "$NOTARIZATION_PROFILE" --wait | grep -E "status:" | tail -1
xcrun stapler staple "$APP_PATH" >/dev/null

echo "▸ dmg"
STAGE=$OUT/dmg; mkdir -p $STAGE
ditto "$APP_PATH" $STAGE/$APP.app; ln -s /Applications $STAGE/Applications
cp Resources/AppIcon.icns $STAGE/.VolumeIcon.icns; SetFile -a C $STAGE
hdiutil create -volname $APP -srcfolder $STAGE -ov -format UDZO "$DMG" >/dev/null 2>&1
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZATION_PROFILE" --wait | grep -E "status:" | tail -1
xcrun stapler staple "$DMG" >/dev/null

echo "▸ appcast"
SPARKLE_BIN="$(ls -d build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin ~/Library/Developer/Xcode/DerivedData/$APP-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"
UPDATES=$OUT/updates; mkdir -p $UPDATES; cp "$DMG" $UPDATES/
"$SPARKLE_BIN/generate_appcast" --account $APP --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" $UPDATES >/dev/null

echo "▸ publish v$VERSION"
gh release view "v$VERSION" -R $REPO >/dev/null 2>&1 || gh release create "v$VERSION" -R $REPO --title "$APP $VERSION" --generate-notes
gh release upload "v$VERSION" -R $REPO --clobber "$UPDATES/$APP-$VERSION.dmg" $UPDATES/appcast.xml
echo "✓ https://github.com/$REPO/releases/tag/v$VERSION"
