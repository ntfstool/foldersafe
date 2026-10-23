# FolderSafe for macOS and iPhone

XcodeGen project (`project.yml` → `xcodegen generate`; the `.xcodeproj` is generated and not checked in).
The vault format lives in the SwiftPM package [`../foldersafe_apple_core`](../foldersafe_apple_core).

## Targets

| Target | What it is |
|---|---|
| `FolderSafeMac` | macOS app (direct distribution, not sandboxed). Embeds the File Provider and FSKit extensions. |
| `FolderSafeMacAppStore` | Same app for the Mac App Store: sandboxed, File Provider only (configuration `AppStore`, compilation condition `APPSTORE`). |
| `FolderSafeMacFileProvider` | File Provider extension for macOS (`FileProvider/`, shared with iOS). Unlocked vaults appear in Finder's sidebar. |
| `FolderSafeFSKit` | FSKit extension (macOS 26+) that mounts a vault as a real folder. Built, but switched off in 1.0 (`AppModel.fskitEnabledInThisRelease`). |
| `FolderSafeiOS` / `FolderSafeiOSFileProvider` | iPhone app and its File Provider extension (Files app). |

## Signing

All identifiers come from **`Config/Signing.xcconfig`**:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID              # your Apple Developer Team ID
FS_BUNDLE_PREFIX = com.example.foldersafe    # a bundle-ID prefix you own
```

Derived from these: bundle IDs (`<prefix>.mac`, `<prefix>.mac.fileprovider`, `<prefix>.mac.fskit`, `<prefix>.ios`,
`<prefix>.ios.fileprovider`), the App Group (macOS `<team>.<prefix>`, iOS `group.<prefix>`) and the shared keychain group
(`<team>.<prefix>.shared`). They reach the entitlements as build settings and the code through Info.plist keys
(`FSBundlePrefix`, `FSAppGroup`, `FSKeychainGroup`, read by `Shared/SharedConfig.swift`). Signing is automatic; Xcode
registers the App IDs and the App Group for your team the first time you build for a device.

Then:

```sh
xcodegen generate
open FolderSafe.xcodeproj
```

The File Provider extension must be enabled once on macOS: System Settings › General › Login Items & Extensions ›
File Providers › FolderSafe. Only one copy of the app should be installed, or macOS may start the wrong extension.

## Layout

```
Mac/App/          macOS app (SwiftUI): model, views, auto-lock, FSKit presenter
Mac/FSKit/        FSKit extension
FileProvider/     File Provider extension (macOS + iOS): item index, enumerator, vault store, change watcher
iOS/App/          iPhone app (SwiftUI)
Shared/           code shared by apps and extensions: VaultService, presenters, vault registry, keychain stores
Config/           Info.plists, entitlements, Signing.xcconfig
FileProviderTests/  offline tests of the extension code against real vaults (swift run -c debug fp-store-tests / fp-extension-tests)
```

`FS_SNAPSHOT_VIEW` (iPhone launch argument) and `FS_SNAPSHOT=<png>` (macOS environment) start a demo mode with fake
vaults, used for screenshots; it never touches real vaults or keys.
