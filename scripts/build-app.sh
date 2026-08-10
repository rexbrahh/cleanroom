#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${CLEANROOM_SIGN_IDENTITY:--}"
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DEFAULT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
VERSION="${CLEANROOM_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${CLEANROOM_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
APP="$ROOT/dist/Cleanroom.app"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -r -- "Invalid Cleanroom version '$VERSION'; expected MAJOR.MINOR.PATCH."
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 -r -- "Invalid Cleanroom build '$BUILD_NUMBER'; expected a positive integer."
  exit 1
fi

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Library/LaunchAgents" \
  "$APP/Contents/Library/LaunchServices" \
  "$APP/Contents/Resources"

/usr/bin/ditto "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/bin/ditto "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$ROOT/Resources/com.rex.cleanroom.agent.plist" \
  "$APP/Contents/Library/LaunchAgents/com.rex.cleanroom.agent.plist"
/usr/bin/ditto "$BIN_PATH/Cleanroom" "$APP/Contents/MacOS/Cleanroom"
/usr/bin/ditto "$BIN_PATH/cleanroom-agent" \
  "$APP/Contents/Library/LaunchServices/cleanroom-agent"
/usr/bin/ditto "$BIN_PATH/cleanroomctl" "$APP/Contents/Resources/cleanroomctl"

/bin/chmod 755 \
  "$APP/Contents/MacOS/Cleanroom" \
  "$APP/Contents/Library/LaunchServices/cleanroom-agent" \
  "$APP/Contents/Resources/cleanroomctl"

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Library/LaunchAgents/com.rex.cleanroom.agent.plist"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi

/usr/bin/codesign "${SIGN_ARGS[@]}" --identifier com.rex.cleanroom.agent \
  "$APP/Contents/Library/LaunchServices/cleanroom-agent"
/usr/bin/codesign "${SIGN_ARGS[@]}" --identifier com.rex.cleanroom.cli \
  "$APP/Contents/Resources/cleanroomctl"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/Cleanroom"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
"$ROOT/scripts/validate-build-version.sh" "$APP" "$VERSION" "$BUILD_NUMBER"

print -r -- "$APP"
