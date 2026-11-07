#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$project_root/dist/Clip32.app"
destination_root="$HOME/Applications"
destination_app="$destination_root/Clip32.app"
bundle_id="com.pranavpalle.clip32"

if [[ ! -d "$source_app" ]]; then
    echo "Build Clip32 first: $project_root/Scripts/build.sh" >&2
    exit 1
fi
if pgrep -x Clip32 >/dev/null; then
    echo "Quit Clip32 from its menu bar menu, then run this installer again." >&2
    exit 1
fi
source_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$source_id" != "$bundle_id" ]]; then
    echo "Refusing to install an unrecognized bundle at $source_app" >&2
    exit 1
fi
codesign --verify --deep --strict "$source_app"

if [[ -e "$destination_app" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$bundle_id" ]]; then
        echo "Refusing to replace an unrecognized app at $destination_app" >&2
        exit 1
    fi
fi

mkdir -p "$destination_root"
stage_root="$(mktemp -d "$destination_root/.clip32-install.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
ditto "$source_app" "$stage_root/Clip32.app"
codesign --verify --deep --strict "$stage_root/Clip32.app"
if [[ -e "$destination_app" ]]; then
    mv "$destination_app" "$stage_root/Previous Clip32.app"
fi
if ! mv "$stage_root/Clip32.app" "$destination_app"; then
    if [[ -d "$stage_root/Previous Clip32.app" ]]; then
        mv "$stage_root/Previous Clip32.app" "$destination_app"
        echo "Installation failed. The previous app was restored." >&2
    else
        echo "Installation failed." >&2
    fi
    exit 1
fi
open "$destination_app" --args "$@"
echo "Installed and opened: $destination_app"
echo "Clip32 appears in the menu bar. Press Command–Shift–C for clipboard history."
