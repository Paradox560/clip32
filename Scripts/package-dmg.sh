#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$project_root/.build"
dist_root="$project_root/dist"
app_path="$dist_root/Clip32.app"
bundle_id="com.pranavpalle.clip32"
notary_profile="${NOTARY_KEYCHAIN_PROFILE:-}"
skip_build=0

case "${1:-}" in
    --skip-build) skip_build=1 ;;
    --help|-h)
        echo "Usage: Scripts/package-dmg.sh [--skip-build]"
        echo "Builds a universal Clip32.app and a drag-to-Applications DMG."
        echo "Optional: SIGNING_IDENTITY='Developer ID Application: …'"
        echo "          NOTARY_KEYCHAIN_PROFILE='saved-notarytool-profile'"
        echo "--skip-build packages the existing dist/Clip32.app without rebuilding."
        exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Usage: Scripts/package-dmg.sh [--skip-build]" >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "DMG packaging requires macOS." >&2
    exit 1
fi
if [[ -n "$notary_profile" && ( -z "${SIGNING_IDENTITY:-}" || "${SIGNING_IDENTITY:-}" == "-" ) ]]; then
    echo "Set SIGNING_IDENTITY to a Developer ID Application identity before notarizing." >&2
    exit 1
fi
if [[ "$skip_build" -eq 0 ]]; then
    "$project_root/Scripts/build.sh"
fi
if [[ ! -d "$app_path" ]]; then
    echo "Missing app bundle. Run Scripts/build.sh first." >&2
    exit 1
fi
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
if [[ "$actual_id" != "$bundle_id" ]]; then
    echo "Refusing to package an unrecognized app bundle." >&2
    exit 1
fi
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
case "$version" in
    *[!0-9.]*|"") echo "Unexpected app version: $version" >&2; exit 1 ;;
esac
architectures="$(lipo -archs "$app_path/Contents/MacOS/Clip32")"
case "$architectures" in
    *arm64*x86_64*|*x86_64*arm64*) architecture_label="universal" ;;
    arm64|x86_64) architecture_label="$architectures" ;;
    *) echo "Unsupported app architectures: $architectures" >&2; exit 1 ;;
esac

mkdir -p "$build_root" "$dist_root"
stage_root="$(mktemp -d "$build_root/dmg.XXXXXX")"
mounted_volume=""
cleanup() {
    if [[ -n "$mounted_volume" ]]; then
        hdiutil detach "$mounted_volume" >/dev/null 2>&1 || true
    fi
    rm -rf "$stage_root"
}
trap cleanup EXIT
stage_volume="$stage_root/volume"
mkdir -p "$stage_volume"
ditto "$app_path" "$stage_volume/Clip32.app"
ln -s /Applications "$stage_volume/Applications"
signature_details="$(codesign -d --verbose=4 "$stage_volume/Clip32.app" 2>&1)"

if [[ -n "$notary_profile" ]]; then
    case "$signature_details" in
        *"Authority=Developer ID Application:"*) ;;
        *) echo "Notarization requires a Developer ID Application-signed build. Set SIGNING_IDENTITY and rebuild." >&2; exit 1 ;;
    esac
    ditto -c -k --sequesterRsrc --keepParent "$stage_volume/Clip32.app" "$stage_root/Clip32-notary.zip"
    xcrun notarytool submit "$stage_root/Clip32-notary.zip" --keychain-profile "$notary_profile" \
        --wait --output-format json > "$stage_root/app-notary.json"
    notary_status="$(plutil -extract status raw -o - "$stage_root/app-notary.json")"
    if [[ "$notary_status" != "Accepted" ]]; then
        cp "$stage_root/app-notary.json" "$dist_root/notarization-app-result.json"
        echo "App notarization was not accepted. See dist/notarization-app-result.json." >&2
        exit 1
    fi
    xcrun stapler staple "$stage_volume/Clip32.app"
    xcrun stapler validate "$stage_volume/Clip32.app"
fi

cat > "$stage_volume/Install Guide.txt" <<'GUIDE'
CLIP32
A clipboard with room to remember.

INSTALL
1. Drag Clip32.app to the Applications folder beside it.
2. Eject this disk image and open Clip32 from Applications.
3. Follow the first-run setup. Enable Accessibility for direct paste.

Clip32 lives in the menu bar and can start automatically when you log in.
Copy normally with Command-C; open history with Command-Shift-C.
Choose your history size in Settings. Text, images, and file references stay
on your Mac. No account or cloud service is required.

Requires macOS 13 or later. This app bundle includes its own executable;
recipients do not need Xcode, Swift, or any developer tools.

UPDATING
Quit Clip32 from its menu bar before replacing the app in Applications.
Your existing history and preferences are retained.
GUIDE
if [[ -z "$notary_profile" ]]; then
    cat >> "$stage_volume/Install Guide.txt" <<'GUIDE'

DEVELOPMENT BUILD
This disk image has not been notarized by Apple. macOS may block a downloaded
copy. A Developer ID-signed, notarized release is needed for normal Gatekeeper
approval. The project includes the signing and notarization workflow.
GUIDE
fi

artifact_name="Clip32-$version-$architecture_label.dmg"
staged_dmg="$stage_root/$artifact_name"
hdiutil create -volname "Clip32" -srcfolder "$stage_volume" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -o "$staged_dmg"
hdiutil verify "$staged_dmg"

# Verify the contents of the actual image, not just the staging folder.
mounted_volume="$stage_root/mounted"
mkdir -p "$mounted_volume"
hdiutil attach "$staged_dmg" -readonly -nobrowse -mountpoint "$mounted_volume" >/dev/null
codesign --verify --deep --strict "$mounted_volume/Clip32.app"
mounted_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mounted_volume/Clip32.app/Contents/Info.plist")"
if [[ "$mounted_id" != "$bundle_id" || "$(readlink "$mounted_volume/Applications")" != "/Applications" || ! -f "$mounted_volume/Install Guide.txt" ]]; then
    echo "The mounted DMG does not contain the expected installer files." >&2
    exit 1
fi
cmp "$app_path/Contents/MacOS/Clip32" "$mounted_volume/Clip32.app/Contents/MacOS/Clip32"
hdiutil detach "$mounted_volume" >/dev/null
mounted_volume=""

if [[ -n "$notary_profile" ]]; then
    signing_identity="${SIGNING_IDENTITY:-}"
    codesign --force --sign "$signing_identity" --timestamp "$staged_dmg"
    xcrun notarytool submit "$staged_dmg" --keychain-profile "$notary_profile" \
        --wait --output-format json > "$stage_root/dmg-notary.json"
    notary_status="$(plutil -extract status raw -o - "$stage_root/dmg-notary.json")"
    if [[ "$notary_status" != "Accepted" ]]; then
        cp "$stage_root/dmg-notary.json" "$dist_root/notarization-dmg-result.json"
        echo "DMG notarization was not accepted. See dist/notarization-dmg-result.json." >&2
        exit 1
    fi
    xcrun stapler staple "$staged_dmg"
    xcrun stapler validate "$staged_dmg"
fi
mv "$staged_dmg" "$dist_root/$artifact_name"
(cd "$dist_root" && shasum -a 256 "$artifact_name" > "$artifact_name.sha256")
echo "Created: $dist_root/$artifact_name"
echo "Checksum: $dist_root/$artifact_name.sha256"
if [[ -z "$notary_profile" ]]; then
    echo "This DMG is not notarized. Developer ID signing and notarization are required for normal downloaded-app approval."
fi
