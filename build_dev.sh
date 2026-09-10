#!/bin/bash
# FluidFold fast development build: xcodegen -> xcodebuild -> /Applications -> launch.
# Usage: ./build_dev.sh          (env: CONFIGURATION=Debug INSTALL_APP=0 LAUNCH_APP=0)
set -euo pipefail

START_TIME=$(date +%s)
APP_NAME="FluidFold"
SCHEME="FluidFold"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_NUMBER="$(git -C "${PROJECT_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${PROJECT_DIR}/build/DerivedData}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
INSTALL_APP="${INSTALL_APP:-1}"
LAUNCH_APP="${LAUNCH_APP:-1}"

# Use a full Xcode, never CommandLineTools, without changing the system selection.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    SELECTED="$(xcode-select -p 2>/dev/null || true)"
    if [[ "${SELECTED}" != *"/Contents/Developer" ]]; then
        CANDIDATE="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)"
        if [ -z "${CANDIDATE}" ]; then
            echo "❌ No Xcode.app found in /Applications"; exit 1
        fi
        export DEVELOPER_DIR="${CANDIDATE}/Contents/Developer"
    fi
fi
echo "Xcode: ${DEVELOPER_DIR:-$(xcode-select -p)}"

# Regenerate the project when project.yml is newer than the .xcodeproj.
if [ ! -d "${PROJECT_DIR}/${APP_NAME}.xcodeproj" ] || [ "${PROJECT_DIR}/project.yml" -nt "${PROJECT_DIR}/${APP_NAME}.xcodeproj/project.pbxproj" ]; then
    command -v xcodegen >/dev/null || { echo "❌ xcodegen missing: brew install xcodegen"; exit 1; }
    (cd "${PROJECT_DIR}" && xcodegen generate --quiet)
    echo "✓ Generated ${APP_NAME}.xcodeproj"
fi

XCCONFIG_ARGS=()
LOCAL_SIGNING_XCCONFIG="${LOCAL_SIGNING_XCCONFIG:-${PROJECT_DIR}/xcconfig/LocalSigning.xcconfig}"
if [ -f "${LOCAL_SIGNING_XCCONFIG}" ]; then
    echo "Using local xcconfig: ${LOCAL_SIGNING_XCCONFIG}"
    XCCONFIG_ARGS=(-xcconfig "${LOCAL_SIGNING_XCCONFIG}")
fi

# shellcheck source=scripts/ensure_codesign_keychain.sh
source "${PROJECT_DIR}/scripts/ensure_codesign_keychain.sh"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}" ensure_codesign_keychain || exit 1

mkdir -p "${PROJECT_DIR}/build"
BUILD_LOG="${PROJECT_DIR}/build/build_dev.log"
echo "Building ${APP_NAME} (${CONFIGURATION})..."
set +e
xcodebuild \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    "${XCCONFIG_ARGS[@]}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    build 2>&1 | tee "${BUILD_LOG}" | grep -E "error:|warning: .*Sources|BUILD (SUCCEEDED|FAILED)" || true
STATUS=${PIPESTATUS[0]}
set -e
if [ "${STATUS}" -ne 0 ]; then
    echo "❌ Build failed (see ${BUILD_LOG})"
    if grep -qi "errSecInternalComponent\|user interaction is not allowed" "${BUILD_LOG}"; then
        echo "   codesign could not access the signing private key. Open Keychain Access → key → Access Control → Always Allow codesign."
    fi
    exit "${STATUS}"
fi

BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[ -d "${BUILT_APP}" ] || { echo "❌ Built app not found at ${BUILT_APP}"; exit 1; }
codesign -dv "${BUILT_APP}" 2>&1 | grep -E "^(Authority=Apple Dev|Authority=Developer ID|TeamIdentifier)" | head -2

if [ "${INSTALL_APP}" = "1" ]; then
    INSTALL_PATH="/Applications/${APP_NAME}.app"
    killall "${APP_NAME}" 2>/dev/null || true
    rm -rf "${INSTALL_PATH}"
    # ditto keeps the signature; same bundle ID + team keeps Screen Recording permission across rebuilds.
    ditto "${BUILT_APP}" "${INSTALL_PATH}"
    xattr -cr "${INSTALL_PATH}" 2>/dev/null || true
    echo "✓ Installed to ${INSTALL_PATH}"
    if [ "${LAUNCH_APP}" = "1" ]; then
        open "${INSTALL_PATH}"
        echo "✓ Launched"
    fi
fi
echo "Done in $(( $(date +%s) - START_TIME ))s"
