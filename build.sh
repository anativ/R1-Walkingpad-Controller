#!/bin/bash
# Builds WalkingPad.app. Requires the Xcode Command Line Tools only.
#
#   ./build.sh              build dist/WalkingPad.app
#   ./build.sh --run        build, then launch it
#   ./build.sh --install    build, then copy to /Applications
#   ./build.sh --zip        build, then zip to dist/WalkingPad.zip
#   UNIVERSAL=1 ./build.sh  build a universal (arm64 + x86_64) binary
#   VERSION=1.2 BUILD=47    stamp CFBundleShortVersionString / CFBundleVersion
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="WalkingPad"
BUNDLE_ID="io.nativ.walkingpad"
DIST="dist"
APP="$DIST/$APP_NAME.app"

BUILD_FLAGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Verifying protocol layer"
swift run -c release padctl selftest

echo "==> Building $APP_NAME"
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Generating icon"
mkdir -p build/icon
swift tools/MakeIcon.swift build/icon >/dev/null
iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

# CoreBluetooth requires a signed bundle. Ad-hoc signing is enough for local use;
# note that the signature changes on every rebuild, so macOS may re-ask for the
# Bluetooth permission after a rebuild.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && echo "    signature ok"

# The CLI helper ships as its own tiny bundle. macOS will not grant Bluetooth access to a
# bare executable at all -- not even one with the usage string linked into its
# __TEXT,__info_plist section -- so padctl has to be the main executable of a real bundle.
echo "==> Assembling padctl.app"
PADCTL_APP="$DIST/padctl.app"
rm -rf "$PADCTL_APP"
mkdir -p "$PADCTL_APP/Contents/MacOS"
cp "$BIN_PATH/padctl" "$PADCTL_APP/Contents/MacOS/padctl"
cp Support/padctl-Info.plist "$PADCTL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string padctl" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :LSUIElement bool true" \
  "$PADCTL_APP/Contents/Info.plist" >/dev/null 2>&1
codesign --force --sign - --identifier "$BUNDLE_ID.padctl" "$PADCTL_APP" >/dev/null 2>&1

# Convenience wrapper so `./dist/padctl <cmd>` works.
cat > "$DIST/padctl" <<'WRAPPER'
#!/bin/bash
# Runs the bundled padctl. Bluetooth commands need permission for your terminal app.
exec "$(dirname "$0")/padctl.app/Contents/MacOS/padctl" "$@"
WRAPPER
chmod +x "$DIST/padctl"

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Replacing the bundle of a RUNNING app terminates it: macOS validates code pages lazily, and
  # an ad-hoc signature cannot be re-validated once the bundle is gone. That silently kills a
  # session someone may be mid-walk in, so refuse by default.
  if pgrep -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    if [[ "${FORCE_INSTALL:-0}" != "1" ]]; then
      echo "!!! $APP_NAME is currently running." >&2
      echo "    Installing would replace its bundle and macOS would terminate it," >&2
      echo "    ending any walk or program in progress." >&2
      echo "    Quit the app first, or re-run with FORCE_INSTALL=1 to override." >&2
      echo "    The build in $APP is ready either way." >&2
      exit 1
    fi
    echo "==> WARNING: $APP_NAME is running and will be terminated (FORCE_INSTALL=1)"
  fi
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "    installed /Applications/$APP_NAME.app"
fi

if [[ "${1:-}" == "--zip" ]]; then
  echo "==> Zipping"
  /usr/bin/ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
  echo "    $DIST/$APP_NAME.zip"
fi

if [[ "${1:-}" == "--run" ]]; then
  echo "==> Launching"
  open "$APP"
fi
