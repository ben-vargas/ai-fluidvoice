#!/bin/bash

# Builds the fork's Release app and installs it as "FluidVoice Plus" next to the official FluidVoice.
#
# Usage:
#   scripts/build-plus.sh
#
# Signs with the first Apple Development identity in the keychain. The team ID is resolved at runtime
# and passed only on the xcodebuild command line, so it never lands in the project file or in git.
# Set FLUIDVOICE_DEVELOPMENT_TEAM to pick a team when the keychain holds several.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${FLUIDVOICE_PLUS_DERIVED_DATA_PATH:-${HOME}/Library/Developer/Xcode/DerivedData/FluidVoicePlus}"
INSTALL_DIR="${FLUIDVOICE_PLUS_INSTALL_DIR:-/Applications}"

PLUS_NAME="FluidVoice Plus"
PLUS_BUNDLE_ID="com.FluidApp.app.plus"

RELEASE_PRODUCTS="${DERIVED_DATA_PATH}/Build/Products/Release"
BUILT_APP="${RELEASE_PRODUCTS}/FluidVoice.app"
STAGING_DIR="${DERIVED_DATA_PATH}/PlusStaging"
STAGED_APP="${STAGING_DIR}/${PLUS_NAME}.app"
INSTALLED_APP="${INSTALL_DIR}/${PLUS_NAME}.app"
ENTITLEMENTS_FILE=""

resolve_development_team() {
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | awk 'NR == 1 { identity = $0 } END { print identity }')"
    [ -n "${identity}" ] || return 0

    if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
        printf '%s\n' "${FLUIDVOICE_DEVELOPMENT_TEAM}"
        return
    fi

    security find-certificate -c "${identity}" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p'
}

resolve_development_identity_hash() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
        | awk 'NR == 1 { print; exit }'
}

replace_with_symlink() {
    local path="$1"
    local target="$2"

    if [ -L "${path}" ] || [ -f "${path}" ]; then
        rm -f "${path}"
    elif [ -d "${path}" ]; then
        rm -R "${path}"
    elif [ -e "${path}" ]; then
        echo "Unexpected file type at ${path}" >&2
        return 1
    fi

    ln -s "${target}" "${path}"
}

# Same CTranscribe.framework layout fix and re-seal that build.sh applies to the Debug product.
normalize_ctranscribe() {
    local app_path="$1"
    local identity_hash="$2"
    local framework="${app_path}/Contents/Frameworks/CTranscribe.framework"
    local versions="${framework}/Versions"
    local version_a="${versions}/A"

    if [ ! -d "${framework}" ]; then
        echo "CTranscribe.framework is missing: ${framework}" >&2
        exit 1
    fi
    if [ ! -d "${versions}" ] || [ -L "${versions}" ] \
        || [ ! -d "${version_a}" ] || [ -L "${version_a}" ] \
        || [ ! -f "${version_a}/CTranscribe" ] || [ -L "${version_a}/CTranscribe" ] \
        || [ ! -d "${version_a}/Resources" ] || [ -L "${version_a}/Resources" ]; then
        echo "CTranscribe.framework has an unexpected layout: ${framework}" >&2
        exit 1
    fi

    echo "Normalizing CTranscribe.framework layout..."
    replace_with_symlink "${versions}/Current" "A"
    replace_with_symlink "${framework}/CTranscribe" "Versions/Current/CTranscribe"
    replace_with_symlink "${framework}/Resources" "Versions/Current/Resources"

    echo "Re-sealing CTranscribe.framework..."
    codesign --force --sign "${identity_hash}" \
        --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags "${framework}"
}

is_plus_running() {
    pgrep -f "${INSTALLED_APP}/Contents/MacOS/" >/dev/null 2>&1
}

main() {
    local development_team
    local identity_hash
    local plist
    local signature_info

    cd "${PROJECT_DIR}"

    identity_hash="$(resolve_development_identity_hash)"
    development_team="$(resolve_development_team)"
    if [ -z "${identity_hash}" ] || [ -z "${development_team}" ]; then
        echo "No valid Apple Development signing identity was found. See ./build.sh for setup steps." >&2
        exit 1
    fi

    # Check before building so a running copy never blocks a finished build halfway through.
    if [ -e "${INSTALLED_APP}" ] && is_plus_running; then
        echo "${PLUS_NAME} is running. Quit it, then run this script again." >&2
        exit 1
    fi

    echo "Building ${PLUS_NAME} (Release)..."
    xcodebuild \
        -project Fluid.xcodeproj \
        -scheme Fluid \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        build \
        DEVELOPMENT_TEAM="${development_team}"

    if [ ! -d "${BUILT_APP}" ]; then
        echo "Release build product is missing: ${BUILT_APP}" >&2
        exit 1
    fi
    if [ ! -x "${BUILT_APP}/Contents/Helpers/fv-serve" ]; then
        echo "fv-serve is missing from the built app: ${BUILT_APP}" >&2
        exit 1
    fi

    normalize_ctranscribe "${BUILT_APP}" "${identity_hash}"

    ENTITLEMENTS_FILE="$(mktemp -t fluidvoice-plus-entitlements)"
    trap 'rm -f "${ENTITLEMENTS_FILE}"' EXIT
    if ! codesign --display --entitlements :- "${BUILT_APP}" > "${ENTITLEMENTS_FILE}" 2>/dev/null; then
        echo "Unable to read the built app's entitlements: ${BUILT_APP}" >&2
        exit 1
    fi

    echo "Staging ${PLUS_NAME}.app..."
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"
    ditto "${BUILT_APP}" "${STAGED_APP}"

    plist="${STAGED_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${PLUS_BUNDLE_ID}" "${plist}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${PLUS_NAME}" "${plist}" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${PLUS_NAME}" "${plist}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${PLUS_NAME}" "${plist}" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${PLUS_NAME}" "${plist}"
    # The fork build sends no analytics to upstream's PostHog project.
    /usr/libexec/PlistBuddy -c "Delete :POSTHOG_API_KEY" "${plist}" 2>/dev/null || true

    echo "Signing ${PLUS_NAME}.app as ${PLUS_BUNDLE_ID}..."
    if [ -s "${ENTITLEMENTS_FILE}" ]; then
        codesign --force --sign "${identity_hash}" \
            --options runtime --timestamp=none \
            --entitlements "${ENTITLEMENTS_FILE}" "${STAGED_APP}"
    else
        codesign --force --sign "${identity_hash}" \
            --options runtime --timestamp=none "${STAGED_APP}"
    fi

    echo "Verifying the signed app..."
    codesign --verify --deep --strict "${STAGED_APP}"
    # Capture first: with pipefail, `grep -q` closing the pipe early would fail the check.
    signature_info="$(codesign -dv "${STAGED_APP}" 2>&1)"
    if ! grep -qx "Identifier=${PLUS_BUNDLE_ID}" <<< "${signature_info}"; then
        echo "Signed identifier is not ${PLUS_BUNDLE_ID}." >&2
        exit 1
    fi

    # The intermediate product carries upstream's bundle ID; don't leave it where LaunchServices can find it.
    rm -rf "${BUILT_APP}"

    if [ -e "${INSTALLED_APP}" ]; then
        if is_plus_running; then
            echo "${PLUS_NAME} started while building. Quit it, then run this script again." >&2
            exit 1
        fi
        echo "Replacing ${INSTALLED_APP}..."
        rm -rf "${INSTALLED_APP}"
    else
        echo "Installing ${INSTALLED_APP}..."
    fi
    ditto "${STAGED_APP}" "${INSTALLED_APP}"
    rm -rf "${STAGING_DIR}"

    codesign --verify --deep --strict "${INSTALLED_APP}"
    echo "Installed ${INSTALLED_APP}"
}

main "$@"
