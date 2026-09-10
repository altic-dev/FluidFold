#!/bin/bash
# FluidFold release build: universal archive, Developer ID signing, notarization, stapling, DMG.
# Usage: ./build_and_notarize.sh            (env: SKIP_NOTARIZE=1 to only sign, PUBLISH=1 to create the GitHub release)
# Prereq (once): xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
set -euo pipefail

APP_NAME="FluidFold"
SCHEME="FluidFold"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_NUMBER="$(git -C "${PROJECT_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR="${PROJECT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/Export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
# Release identities live in the gitignored release.env (see release.env.example) or the environment.
[ -f "${PROJECT_DIR}/release.env" ] && source "${PROJECT_DIR}/release.env"
: "${DEVELOPER_ID:?set DEVELOPER_ID (Developer ID Application: Name (TEAMID)) in release.env}"
: "${TEAM_ID:?set TEAM_ID in release.env}"
NOTARIZATION_PROFILE="${NOTARIZATION_PROFILE:-notarize}"

if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p)" != *"/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"
fi
command -v xcodegen >/dev/null || { echo "❌ brew install xcodegen"; exit 1; }
(cd "${PROJECT_DIR}" && xcodegen generate --quiet)

# shellcheck source=scripts/ensure_codesign_keychain.sh
source "${PROJECT_DIR}/scripts/ensure_codesign_keychain.sh"
SIGNING_IDENTITY="Developer ID Application" ensure_codesign_keychain || exit 1

VERSION="$(defaults read "${PROJECT_DIR}/Info.plist" CFBundleShortVersionString 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Info.plist")"
echo "━━ ${APP_NAME} ${VERSION}: archive (universal, Developer ID)"
rm -rf "${BUILD_DIR}"; mkdir -p "${BUILD_DIR}"
xcodebuild archive \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" -scheme "${SCHEME}" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "${ARCHIVE_PATH}" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${DEVELOPER_ID}" DEVELOPMENT_TEAM="${TEAM_ID}" \
    2>&1 | grep -E "error:|warning: .*Sources|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "${ARCHIVE_PATH}" ] || { echo "❌ archive failed"; exit 1; }

cat > "${BUILD_DIR}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" 2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
[ -d "${APP_PATH}" ] || { echo "❌ export failed"; exit 1; }

echo "━━ verify"
lipo -archs "${APP_PATH}/Contents/MacOS/${APP_NAME}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 | tail -2
codesign -dv "${APP_PATH}" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime"

DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "━━ notarize"
    ZIP="${BUILD_DIR}/${APP_NAME}.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP}"
    xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARIZATION_PROFILE}" --wait 2>&1 | tail -4
    xcrun stapler staple "${APP_PATH}" | tail -1
    spctl --assess --type execute --verbose=2 "${APP_PATH}" 2>&1 | tail -1
fi

echo "━━ dmg"
STAGE="${BUILD_DIR}/dmg"; rm -rf "${STAGE}"; mkdir -p "${STAGE}"
ditto "${APP_PATH}" "${STAGE}/${APP_NAME}.app"; ln -s /Applications "${STAGE}/Applications"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${STAGE}/.VolumeIcon.icns"; SetFile -a C "${STAGE}" 2>/dev/null || true
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARIZATION_PROFILE}" --wait 2>&1 | grep -E "status:" | tail -1
    xcrun stapler staple "${DMG}" | tail -1
fi
echo "━━ appcast"
SPARKLE_BIN="$(ls -d ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
[ -x "${SPARKLE_BIN}/generate_appcast" ] || { echo "❌ generate_appcast not found (resolve packages in Xcode first)"; exit 1; }
UPDATES="${BUILD_DIR}/updates"; rm -rf "${UPDATES}"; mkdir -p "${UPDATES}"; cp "${DMG}" "${UPDATES}/"
"${SPARKLE_BIN}/generate_appcast" --account "${APP_NAME}" \
    --download-url-prefix "https://github.com/altic-dev/${APP_NAME}/releases/download/v${VERSION}/" "${UPDATES}" | tail -1
echo "✅ ${DMG}"
echo "✅ ${UPDATES}/appcast.xml"
if [ "${PUBLISH:-0}" = "1" ]; then
    echo "━━ publish v${VERSION}"
    gh release view "v${VERSION}" >/dev/null 2>&1 || gh release create "v${VERSION}" --title "${APP_NAME} ${VERSION}" --generate-notes
    gh release upload "v${VERSION}" --clobber "${UPDATES}/${APP_NAME}-${VERSION}.dmg" "${UPDATES}/appcast.xml"
    echo "✅ https://github.com/altic-dev/${APP_NAME}/releases/tag/v${VERSION}"
fi
