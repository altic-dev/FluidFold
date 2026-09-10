#!/bin/bash
# Shared pre-build guard for code signing.
# Ensures the login keychain is unlocked and that codesign can actually use the
# selected Developer ID private key. The classic symptom of a failure here is
# `errSecInternalComponent` from codesign during the xcodebuild/framework signing
# step — the certificate is present, but the keychain won't release the key.
#
# Source this from build scripts BEFORE invoking xcodebuild:
#   source "$(dirname "$0")/scripts/ensure_codesign_keychain.sh"
#
# Optional env overrides:
#   SIGNING_IDENTITY   - identity name to verify (default: auto-detect Developer ID)
#   KEYCHAIN_PATH      - keychain to unlock (default: login keychain)
#   KEYCHAIN_PASSWORD  - if set, used to unlock non-interactively (never prompt to type it;
#                        export it in your shell or a gitignored env file)

ensure_codesign_keychain() {
    local keychain_path="${KEYCHAIN_PATH:-${HOME}/Library/Keychains/login.keychain-db}"
    local signing_identity="${SIGNING_IDENTITY:-Developer ID Application}"

    if [ ! -f "${keychain_path}" ]; then
        echo "⚠️  Keychain not found at: ${keychain_path}"
        echo "    Set KEYCHAIN_PATH to the correct keychain file."
        return 1
    fi

    # 1) Check whether the keychain is locked. `show-keychain-info` returns
    #    non-zero ("User interaction is not allowed") when locked.
    local was_locked=0
    if ! security show-keychain-info "${keychain_path}" >/dev/null 2>&1; then
        was_locked=1
    fi

    # 2) If locked, try to unlock. Prefer a non-interactive password from the
    #    env so CI / background runs don't hang on an invisible GUI prompt.
    #    Without KEYCHAIN_PASSWORD, fall back to the interactive prompt only
    #    when stdin is a TTY; otherwise bail with a clear message.
    if [ "${was_locked}" = "1" ]; then
        echo "🔐 Login keychain is locked."
        if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
            if ! security unlock-keychain -p "${KEYCHAIN_PASSWORD:-}" "${keychain_path}" 2>/dev/null; then
                echo "❌ KEYCHAIN_PASSWORD was set but failed to unlock the keychain."
                return 1
            fi
            echo "   Unlocked via KEYCHAIN_PASSWORD."
        elif [ -t 0 ]; then
            echo "   Unlocking (enter your login password):"
            if ! security unlock-keychain "${keychain_path}" 2>/dev/null; then
                echo "❌ Could not unlock keychain: ${keychain_path}"
                return 1
            fi
        else
            echo "❌ Cannot unlock keychain non-interactively (no TTY, no KEYCHAIN_PASSWORD)."
            echo "   Fix one of:"
            echo "     • Run this script from an interactive terminal so the unlock prompt appears"
            echo "     • Export KEYCHAIN_PASSWORD (e.g. in a gitignored ~/.fluidvoice_env)"
            echo "     • Open Keychain Access and unlock 'login' manually, then re-run"
            echo ""
            echo "   To stop this from recurring, also:"
            echo "     Keychain Access → right-click 'login' → Change Settings →"
            echo "     uncheck 'Lock after X minutes' and 'Lock when sleeping'."
            return 1
        fi
    fi

    # 3) Confirm a usable Developer ID identity is reachable. This forces the
    #    keychain ACL check up-front so the failure happens before a multi-minute
    #    xcodebuild run, not inside it.
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${signing_identity}"; then
        echo "⚠️  No codesigning identity matching '${signing_identity}' was found."
        echo "    Available identities:"
        security find-identity -v -p codesigning 2>/dev/null | sed 's/^/      /' || true
        echo "    Set SIGNING_IDENTITY to override, or import your Developer ID certificate."
        return 1
    fi

    echo "🔐 Keychain unlocked; signing identity available."
    return 0
}
