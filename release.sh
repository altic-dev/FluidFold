#!/bin/bash
# Release: preflight, universal build, Developer ID, notarize, DMG, Sparkle appcast, GitHub release, verify.
# Needs release.env (copy release.env.example) and a notarytool keychain profile.
# Version comes from MARKETING_VERSION in project.yml. Build number = MAJOR*10000 + MINOR*100 + PATCH (always increases with the version).
set -euo pipefail
cd "$(dirname "$0")"
APP=FluidFold
REPO=altic-dev/FluidFold
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

# ── Preflight ───────────────────────────────────────────────────────────────
[ -f release.env ] || fail "copy release.env.example to release.env"
source release.env
: "${DEVELOPER_ID:?}" "${TEAM_ID:?}" "${NOTARIZATION_PROFILE:?}"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *\(.*\)$/\1/p' project.yml | tr -d '"')"
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "MARKETING_VERSION '$VERSION' is not MAJOR.MINOR.PATCH"
BUILD_NUMBER=$(( BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3] ))
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || fail "working tree not clean"
[ "$(git branch --show-current)" = main ] || fail "not on main"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not pushed (or is behind origin)"
[ -z "$(git tag -l "$TAG")" ] || fail "tag $TAG already exists"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated"
! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || fail "release $TAG already exists"

CURRENT_BUILD="$(curl -sfL "$FEED" | sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' | head -1 || true)"
if [ -n "$CURRENT_BUILD" ]; then
    [ "$BUILD_NUMBER" -gt "$CURRENT_BUILD" ] || fail "build $BUILD_NUMBER is not above the live build $CURRENT_BUILD"
fi
LATEST_TAG="$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
if [ -n "$LATEST_TAG" ]; then
    [ "$(printf '%s\n%s\n' "${LATEST_TAG#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] || fail "$VERSION is not above the latest release $LATEST_TAG"
fi

xcrun notarytool history --keychain-profile "$NOTARIZATION_PROFILE" >/dev/null 2>&1 || fail "notarytool profile '$NOTARIZATION_PROFILE' missing"
ids="$(security find-identity -v -p codesigning)"; [[ "$ids" == *"$DEVELOPER_ID"* ]] || fail "signing identity not in keychain: $DEVELOPER_ID"
command -v xcodegen >/dev/null || fail "brew install xcodegen"
[ -n "${DEVELOPER_DIR:-}" ] || export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"
source scripts/ensure_codesign_keychain.sh
SIGNING_IDENTITY="Developer ID Application" ensure_codesign_keychain

OUT=build/release
DD=$OUT/DerivedData
ARCHIVE=$OUT/$APP.xcarchive
APP_PATH=$OUT/export/$APP.app
DMG=$OUT/$APP-$VERSION.dmg
UPDATES=$OUT/updates
rm -rf "$OUT"; mkdir -p "$OUT" "$UPDATES"
echo "  $APP $VERSION (build $BUILD_NUMBER) from $(git rev-parse --short HEAD)"

# ── Build ───────────────────────────────────────────────────────────────────
step "archive"
xcodegen generate --quiet
xcodebuild -resolvePackageDependencies -project $APP.xcodeproj -scheme $APP -derivedDataPath "$DD" >"$OUT/resolve.log" 2>&1 || fail "package resolve failed, see $OUT/resolve.log"
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || fail "Sparkle tools missing at $SPARKLE_BIN"
EXPECTED_KEY="$(sed -n 's/^ *SPARKLE_PUBLIC_ED_KEY: *"\(.*\)"$/\1/p' project.yml)"
[ "$("$SPARKLE_BIN/generate_keys" --account $APP -p 2>/dev/null)" = "$EXPECTED_KEY" ] || fail "Sparkle EdDSA key in keychain does not match SPARKLE_PUBLIC_ED_KEY in project.yml"

xcodebuild archive -project $APP.xcodeproj -scheme $APP -configuration Release \
    -destination generic/platform=macOS -archivePath "$ARCHIVE" -derivedDataPath "$DD" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    >"$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head; fail "archive failed, see $OUT/archive.log"; }

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
    >"$OUT/export.log" 2>&1 || fail "export failed, see $OUT/export.log"

step "verify build"
plist="$APP_PATH/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$VERSION" ] || fail "built version mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$BUILD_NUMBER" ] || fail "built build number mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" = "$FEED" ] || fail "built SUFeedURL mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" = "$EXPECTED_KEY" ] || fail "built SUPublicEDKey mismatch"
[ "$(lipo -archs "$APP_PATH/Contents/MacOS/$APP")" = "x86_64 arm64" ] || fail "not universal"
codesign --verify --deep --strict "$APP_PATH" || fail "codesign verify failed"
for fw in Sparkle MediaRemoteAdapter; do
    fwbin="$APP_PATH/Contents/Frameworks/$fw.framework/$fw"
    [ -f "$fwbin" ] || fail "$fw.framework missing"
    [ "$(lipo -archs "$fwbin")" = "x86_64 arm64" ] || fail "$fw.framework is not universal"
    sig="$(codesign -dv "$fwbin" 2>&1)"; [[ "$sig" == *"(runtime)"* ]] || fail "$fw.framework lacks hardened runtime"
    sigv="$(codesign -dvv "$fwbin" 2>&1)"; [[ "$sigv" == *"Authority=Developer ID Application"* ]] || fail "$fw.framework not signed with Developer ID"
done
[ -f "$APP_PATH/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle/Contents/Resources/run.pl" ] \
    || [ -f "$APP_PATH/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl" ] \
    || fail "MediaRemoteAdapter resource bundle (run.pl) missing: media pause would silently do nothing"

# ── Notarize ────────────────────────────────────────────────────────────────
notarize() {   # notarize <file to submit: zip or dmg> <bundle to staple>
    local json
    json="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARIZATION_PROFILE" --wait --output-format json 2>"$OUT/notary.err")" \
        || { cat "$OUT/notary.err"; fail "notarytool submit failed for $1"; }
    if [ "$(echo "$json" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null)" != "Accepted" ]; then
        local id; id="$(echo "$json" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARIZATION_PROFILE" || true
        fail "notarization rejected for $1"
    fi
    xcrun stapler staple "$2" >/dev/null || fail "staple failed for $2"
}
step "notarize app"
ditto -c -k --keepParent "$APP_PATH" $OUT/$APP.zip
notarize $OUT/$APP.zip "$APP_PATH"
spctl --assess --type execute "$APP_PATH" 2>/dev/null || fail "Gatekeeper rejects the app"

step "dmg"
STAGE=$OUT/dmg; mkdir -p $STAGE
ditto "$APP_PATH" $STAGE/$APP.app; ln -s /Applications $STAGE/Applications
cp Resources/AppIcon.icns $STAGE/.VolumeIcon.icns; SetFile -a C $STAGE
hdiutil create -volname $APP -srcfolder $STAGE -ov -format UDZO "$DMG" >"$OUT/dmg.log" 2>&1 || fail "hdiutil failed, see $OUT/dmg.log"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG" || fail "dmg signing failed"
notarize "$DMG" "$DMG"

step "appcast"
cp "$DMG" "$UPDATES/"
"$SPARKLE_BIN/generate_appcast" --account $APP --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$UPDATES" >"$OUT/appcast.log" 2>&1 || fail "generate_appcast failed, see $OUT/appcast.log"
grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$UPDATES/appcast.xml" || fail "appcast does not carry build $BUILD_NUMBER"
grep -q "sparkle:minimumSystemVersion>15.2<" "$UPDATES/appcast.xml" || fail "appcast minimum system version is not 15.2"

# ── Publish (draft → assets → live) ─────────────────────────────────────────
step "publish $TAG"
gh release create "$TAG" -R "$REPO" --draft --target "$(git rev-parse HEAD)" --title "$APP $VERSION" --generate-notes >/dev/null
gh release upload "$TAG" -R "$REPO" "$UPDATES/$APP-$VERSION.dmg" "$UPDATES/appcast.xml" >/dev/null \
    || { gh release delete "$TAG" -R "$REPO" --yes >/dev/null 2>&1; fail "asset upload failed; draft removed"; }
gh release edit "$TAG" -R "$REPO" --draft=false --latest >/dev/null
git fetch -q origin --tags

step "verify live feed"
for i in 1 2 3 4 5 6; do
    LIVE="$(curl -sfL "$FEED" | sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' | head -1 || true)"
    [ "$LIVE" = "$BUILD_NUMBER" ] && break
    sleep 10
done
[ "$LIVE" = "$BUILD_NUMBER" ] || fail "live appcast shows build '$LIVE', expected $BUILD_NUMBER"
URL="$(sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' "$UPDATES/appcast.xml")"
curl -sfL -o "$OUT/downloaded.dmg" "$URL" || fail "enclosure URL does not download: $URL"
cmp -s "$OUT/downloaded.dmg" "$DMG" || fail "downloaded DMG differs from the built one"
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$UPDATES/appcast.xml")"
"$SPARKLE_BIN/sign_update" --account $APP --verify "$OUT/downloaded.dmg" "$SIG" >/dev/null 2>&1 || fail "EdDSA signature does not verify against the public key"
echo "✓ $APP $VERSION (build $BUILD_NUMBER) is live: https://github.com/$REPO/releases/tag/$TAG"
