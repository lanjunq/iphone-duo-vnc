#!/bin/zsh
# Typechecks the iOS app sources (App/*.swift) WITHOUT Xcode, against the Mac Catalyst UIKit / SwiftUI /
# MetalKit that ship inside the Command Line Tools macOS SDK. It catches type, API-name, optional,
# access-control and actor-isolation errors; it does not link, sign or run anything.
#
# Differences from a real iOS build (handled with shims in scripts/typecheck-shims/):
# - App/DuoHardware.swift is replaced by a stub: the CLT SDK is 27.0, the Duo API is iOS 27.1+.
# - `@State` is rewritten to `@ShimState` in a scratch copy: in the 27 SDK `@State` is macro-backed and
#   the CLT toolchain has no SwiftUIMacros plugin.
# Once Xcode is usable, `xcodebuild` (see App/README.md) is the real check.
set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
IOSFW="$SDK/System/iOSSupport/System/Library/Frameworks"
SCRATCH="$ROOT/.build/catalyst"
COPY="$ROOT/.build/catalyst-typecheck"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --triple arm64-apple-ios17.0-macabi --sdk "$SDK" \
  -Xswiftc -Fsystem -Xswiftc "$IOSFW" -Xcc -iframework -Xcc "$IOSFW" --product DuoVNCSession \
  > "$ROOT/.build/catalyst-build.log" 2>&1 || { cat "$ROOT/.build/catalyst-build.log"; exit 1; }
MODULES="$SCRATCH/out/Products/Debug-maccatalyst"

rm -rf "$COPY"; mkdir -p "$COPY"
for f in App/*.swift; do
  b="$(basename "$f")"
  [[ "$b" == DuoHardware.swift ]] && continue
  sed -e 's/@State /@ShimState /g' -e 's/= State(initialValue:/= ShimState(initialValue:/g' "$f" > "$COPY/$b"
done
cp scripts/typecheck-shims/DuoHardwareStub.swift.txt "$COPY/DuoHardwareStub.swift"
cp scripts/typecheck-shims/StateShim.swift.txt "$COPY/StateShim.swift"

cd "$COPY"
xcrun swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-ios27.0-macabi -sdk "$SDK" \
  -Fsystem "$IOSFW" -I "$SDK/System/iOSSupport/usr/lib/swift" -I "$MODULES" -module-name DuoVNC \
  *.swift "$@"
echo "App typecheck (Mac Catalyst, CLT SDK): OK"
