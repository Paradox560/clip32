# Clip32

A native macOS menu bar clipboard app. Copy normally with **⌘C**; open your history with **⌘⇧C**. Clip32 keeps up to 32 entries, stays in the background, and registers to launch when you log in.

## Install

Requires macOS 13 or newer and Xcode or the Swift command-line tools. There are no downloaded dependencies.

```sh
./Scripts/build.sh
./Scripts/install.sh
```

The installer puts `Clip32.app` in `~/Applications` and opens it. Look for the clipboard icon in the menu bar; Clip32 does not occupy a Dock slot. Install before enabling permissions, so macOS associates them with the app's permanent location. To build with your own signing certificate, set `SIGNING_IDENTITY` when running the build script. The default build is ad-hoc signed for local use, not notarized for distribution.

## Use

- **⌘C** captures copied text, images, and files. Copy commands from menus also work.
- **⌘⇧C** opens clipboard history. Search to filter, use the arrow keys to move, and press Return to choose an entry. Escape dismisses the panel.
- Selecting an entry restores it to the clipboard and pastes into the app you were using. On first use, enable Clip32 in **System Settings → Privacy & Security → Accessibility**. Until permission is granted, the entry is copied and you can press **⌘V** yourself. Direct paste can be turned off in Settings.
- Pin entries you want to keep. Pinned entries count toward the same total of **32**; the oldest unpinned entry is discarded when space is needed. If all 32 are pinned, unpin or delete one to save new copies. Copying identical content moves its existing entry to the front.
- Settings offers **⌃⌥C** and **⌘⌥C** as alternatives if **⌘⇧C** conflicts with another app. Only the selected shortcut is reserved.
- Pause capture or clear recent history from the app. Clearing recent history keeps pinned entries.
- Launch at login is enabled on first launch. If macOS asks for approval, allow Clip32 in **System Settings → General → Login Items**. You can disable it in Clip32's Settings.

Files are stored as references to their original locations, not as duplicate file contents. Moved or deleted files cannot be restored. Rich text and supported image representations are preserved, with a **16 MiB limit per entry**; oversized or unsupported clipboard content is skipped with a message. History starts with new copies after the app opens and persists across restarts.

## Privacy and storage

Clip32 does not use the network or upload clipboard data. History is saved locally in `~/Library/Application Support/Clip32`, with permissions restricted to your user account. This history is **not encrypted**. Common password-manager confidential, concealed, and transient pasteboard markers are excluded; apps that do not mark sensitive content can still have that content captured. Pause capture before copying anything you do not want saved.

The shortcut and capture do not require Accessibility or Input Monitoring permissions. Accessibility is used only for direct paste. When rebuilding an ad-hoc signed app, macOS may require you to remove and re-add Clip32 in Accessibility settings; quit the old copy before installing an update.

## Development

```sh
swift test --scratch-path .build
./Scripts/build.sh
```

The project uses Swift Package Manager, AppKit, SwiftUI, and system frameworks. `Sources/ClipCore` contains history and clipboard capture; `Sources/Clip32` contains the menu bar app and macOS integration. The icon is rendered locally by `Scripts/GenerateAppIcon.swift`.

The build produces `dist/Clip32.app`. Opening the bundled app is required for login-item registration; running the bare Swift executable is insufficient. The installer refuses to overwrite an app with a different bundle identifier and asks you to quit a running Clip32 before replacement.
