#!/bin/zsh
# Builds, signs and installs the app on a connected iPhone.
#
# Before the first run:
#   - Xcode > Settings > Accounts: sign in with your Apple ID (a free "Personal Team" works).
#   - cp App/Signing.xcconfig.example App/Signing.xcconfig and set DEVELOPMENT_TEAM.
#   - Connect the phone with a cable, tap Trust, enable Settings > Privacy & Security > Developer Mode.
# The phone must be unlocked while this runs. With a free Apple ID the profile lasts 7 days; run this
# again to renew (saved hosts and Keychain passwords survive).
#
#   zsh scripts/install-device.sh                 # the first connected physical device
#   DUOVNC_DEVICE=<udid> zsh scripts/install-device.sh
set -e
cd "$(dirname "$0")/.."
DEVICE=${DUOVNC_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$/) { print $i; exit } }')}
if [ -z "$DEVICE" ]; then
  echo "No physical device found. Check: xcrun devicectl list devices" >&2
  exit 1
fi
xcodegen generate
# The destination must be the device itself: a generic iOS build leaves the device out of the
# provisioning profile and the install then fails with 0xe8008012.
xcodebuild -project DuoVNC.xcodeproj -scheme DuoVNC -configuration Debug -destination "id=$DEVICE" \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  | grep -E 'error|BUILD' || true
APP=build/DerivedData/Build/Products/Debug-iphoneos/DuoVNC.app
echo "profile expires: $(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -)"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E 'App installed|bundleID|ERROR|Reason|Suggestion'
