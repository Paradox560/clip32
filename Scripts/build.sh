#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="com.pranavpalle.clip32"
build_root="$project_root/.build"
dist_root="$project_root/dist"
app_path="$dist_root/Clip32.app"
signing_identity="${SIGNING_IDENTITY:--}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Clip32 must be built on macOS 13 or newer." >&2
    exit 1
fi

# A single download works on both Apple silicon and Intel Macs. For a faster
# development build, explicitly use CLIP32_ARCHS=arm64 or CLIP32_ARCHS=x86_64.
read -r -a architectures <<< "${CLIP32_ARCHS:-arm64 x86_64}"
if [[ ${#architectures[@]} -lt 1 || ${#architectures[@]} -gt 2 ]]; then
    echo "CLIP32_ARCHS must contain arm64, x86_64, or both." >&2
    exit 1
fi
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
    esac
done
if [[ ${#architectures[@]} -eq 2 && "${architectures[0]}" == "${architectures[1]}" ]]; then
    echo "CLIP32_ARCHS must not repeat an architecture." >&2
    exit 1
fi

mkdir -p "$build_root" "$dist_root"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
binaries=()
for architecture in "${architectures[@]}"; do
    swift_arguments=(--package-path "$project_root" --scratch-path "$build_root/release-$architecture"
        --cache-path "$build_root/swiftpm-cache" --config-path "$build_root/swiftpm-config"
        --security-path "$build_root/swiftpm-security" --manifest-cache local --configuration release
        --triple "$architecture-apple-macosx13.0")
    if [[ "${CLIP32_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
        swift_arguments+=(--disable-sandbox)
    fi
    swift build "${swift_arguments[@]}"
    bin_path="$(swift build "${swift_arguments[@]}" --show-bin-path)"
    binaries+=("$bin_path/Clip32")
done

swiftc "$project_root/Scripts/GenerateAppIcon.swift" \
    -module-cache-path "$build_root/module-cache" \
    -o "$build_root/GenerateAppIcon"
"$build_root/GenerateAppIcon" "$build_root/AppIcon.iconset" "$build_root/AppIcon.native.icns"
if ! iconutil -c icns "$build_root/AppIcon.iconset" -o "$build_root/AppIcon.icns" 2>"$build_root/iconutil.log"; then
    echo "iconutil conversion failed; using the validated native ICNS container."
    cp "$build_root/AppIcon.native.icns" "$build_root/AppIcon.icns"
fi

stage_root="$(mktemp -d "$build_root/package.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/Clip32.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"
if [[ ${#binaries[@]} -eq 1 ]]; then
    cp "${binaries[0]}" "$stage_app/Contents/MacOS/Clip32"
else
    lipo -create "${binaries[@]}" -output "$stage_app/Contents/MacOS/Clip32"
fi
chmod 755 "$stage_app/Contents/MacOS/Clip32"
lipo "$stage_app/Contents/MacOS/Clip32" -verify_arch "${architectures[@]}"
for resource in "$project_root"/Resources/*; do
    [[ -e "$resource" ]] || continue
    [[ "$(basename "$resource")" == "Info.plist" ]] && continue
    ditto "$resource" "$stage_app/Contents/Resources/$(basename "$resource")"
done
cp "$build_root/AppIcon.icns" "$stage_app/Contents/Resources/AppIcon.icns"
plutil -lint "$stage_app/Contents/Info.plist"
signing_arguments=(--force --sign "$signing_identity" --identifier "$bundle_id" --options runtime)
if [[ "$signing_identity" == "-" ]]; then
    signing_arguments+=(--timestamp=none)
else
    signing_arguments+=(--timestamp)
fi
codesign "${signing_arguments[@]}" "$stage_app"
codesign --verify --deep --strict "$stage_app"

if [[ -e "$app_path" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$bundle_id" ]]; then
        echo "Refusing to replace an unrecognized app at $app_path" >&2
        exit 1
    fi
    rm -rf "$app_path"
fi
ditto "$stage_app" "$app_path"
echo "Built: $app_path (${architectures[*]})"
if [[ "$signing_identity" == "-" ]]; then
    echo "Local development build: ad-hoc signed, not Apple notarized."
fi
echo "Install locally: $project_root/Scripts/install.sh"
echo "Create a DMG: $project_root/Scripts/package-dmg.sh --skip-build"
