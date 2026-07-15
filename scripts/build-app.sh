#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${CLEANROOM_SIGN_IDENTITY:--}"
APP="$ROOT/dist/Cleanroom.app"

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

/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP/Contents/Library/LaunchServices/cleanroom-agent"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/cleanroomctl"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/Cleanroom"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

print -r -- "$APP"
