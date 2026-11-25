# Duo VNC — iOS app

The iPhone app: SwiftUI host list + a UIKit session screen (Metal framebuffer, aim-then-click pointer,
loupe, toolbar, secure password entry). Everything that does not need UIKit lives in the Swift package
(`Sources/DuoVNCKit`, `Sources/DuoVNCSession`) and is unit-tested with `scripts/test.sh`.

Status: builds with Xcode 27.2 and runs in the iPhone Duo simulator and on a real iPhone Duo.

## Files

| File | What |
|---|---|
| `DuoVNCApp.swift` | `@main` SwiftUI app |
| `AppModel.swift` | saved hosts (`HostStore` JSON in Application Support) + passwords (`KeychainStore`), `SessionSettings` |
| `HostListView.swift`, `HostEditView.swift` | host list, 演示模式, settings, add/edit sheet, `HostPolicy` warn/block alerts |
| `SessionScreen.swift` | `UIViewControllerRepresentable` wrapper |
| `SessionViewController.swift` | session screen: layout, gestures → `PointerEngine` → `SessionController`, toolbar, hardware keyboard, TOFU alert |
| `FramebufferMetalView.swift` | MTKView renderer, shader compiled at runtime from a string |
| `CursorOverlayView.swift`, `LoupeView.swift`, `ConnectionHUDView.swift`, `SessionToolbarView.swift` | overlays |
| `KeyInputView.swift`, `SecureEntryViewController.swift` | soft keyboard responder; password / 验证码 sheet |
| `DuoHardware.swift` | the only file using iOS 27.1 Duo API (`reservedRegions(kind:options:)`, `UIHingeInteraction`) |
| `NetworkMonitor.swift` | NWPathMonitor → reconnect when the network comes back |
| `Base.xcconfig`, `Signing.xcconfig.example` | bundle id + optional signing settings |

`project.yml` (repo root) is the XcodeGen spec; `DuoVNC.xcodeproj` and `App/Info.plist` are generated
and gitignored.

## One-time setup

1. Xcode 27.1 or later, with its license accepted and first launch finished
   (`sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`), and
   [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Apple ID in Xcode: Xcode > Settings > Accounts > + > Apple Account. A free Apple ID gets a
   "Personal Team"; a paid Developer Program account gets a normal team.
3. Team ID: `cp App/Signing.xcconfig.example App/Signing.xcconfig` and set `DEVELOPMENT_TEAM`.
   - Free: `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` prints the `teamID` of
     the Personal Team once the Apple ID is signed in.
   - Paid: developer.apple.com > Account > Membership details.
   - If the team reports that the bundle identifier is unavailable, set your own
     `PRODUCT_BUNDLE_IDENTIFIER` in Signing.xcconfig.
4. The phone: connect it with a cable and tap Trust. Then enable Settings > Privacy & Security >
   Developer Mode (the phone restarts and asks once more after unlocking).

## Build, install, launch

```sh
zsh scripts/install-device.sh
```

The script generates the Xcode project, builds for the connected phone, signs, and installs. The phone
must be unlocked. Things that go wrong:

- "Developer Mode disabled": see step 4 above.
- Install fails with `0xe8008012` ("This provisioning profile cannot be installed on this device"):
  the build was made for a generic destination, so the phone is not in the profile. The script avoids
  this by building with `-destination id=<device>`.
- The app is installed but will not open: with a free Apple ID, trust the developer once on the phone
  in Settings > General > VPN & Device Management.
- A free profile expires after 7 days. Run the script again; saved hosts and Keychain passwords survive.

Simulator (no signing; demo mode works offline):

```sh
xcodegen generate
xcodebuild -project DuoVNC.xcodeproj -scheme DuoVNC -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -derivedDataPath build/DerivedData build
xcrun simctl boot "iPhone Duo"
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/DuoVNC.app
xcrun simctl launch booted com.lanjunq.duovnc -DuoVNCDemo
```

Debug builds can also connect straight to a server without touching the screen, which is useful in the
simulator: launch with the environment variables `DUOVNC_AUTO_HOST`, `DUOVNC_AUTO_USER`,
`DUOVNC_AUTO_PASS` and optionally `DUOVNC_AUTO_KEY` (the pinned key fingerprint), each prefixed with
`SIMCTL_CHILD_` when passed through `simctl launch`.

## Using it with a Mac

1. On the Mac: System Settings > General > Sharing > Screen Sharing on. Allow the account you will
   log in with. Optionally set a "VNC viewers may control screen with password".
2. On the Duo: Tailscale connected. Add a host with the Mac's Tailscale address (or
   its MagicDNS name), login method "Mac 账号" with the macOS short user name and password.
3. First connection shows the Mac's key fingerprint (type 33). Check it and accept. A different key later
   blocks the connection; clear the pinned fingerprint in the host's edit sheet only if you know why
   it changed.
4. Gestures: drag with one finger to aim (loupe shows the exact pixel), tap 点击 to click. Two-finger
   tap = right click, two-finger drag = scroll, pinch = zoom, long press then drag = drag with the
   button held. When zoomed to the 设置 threshold (default 4x), a tap clicks directly.
5. Passwords: 密码 opens a secure field (AutoFill works). 发送 types it as key presses; 发送并回车 adds
   Return. Nothing goes through the clipboard or into logs.
