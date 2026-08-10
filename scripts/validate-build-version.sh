#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  print -u2 -r -- "Usage: $0 APP_PATH EXPECTED_VERSION EXPECTED_BUILD"
  exit 64
fi

APP="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
INFO="$APP/Contents/Info.plist"
CLI="$APP/Contents/Resources/cleanroomctl"
AGENT="$APP/Contents/Library/LaunchServices/cleanroom-agent"

[[ -f "$INFO" && -x "$CLI" && -x "$AGENT" ]] || {
  print -u2 -r -- "Version validation requires a complete Cleanroom.app bundle."
  exit 1
}

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
CLI_IDENTITY="$($CLI --version)"
AGENT_IDENTITY="$($AGENT --version)"
EXPECTED_IDENTITY="$EXPECTED_VERSION ($EXPECTED_BUILD)"

if [[ "$APP_VERSION" != "$EXPECTED_VERSION" || "$APP_BUILD" != "$EXPECTED_BUILD" ]]; then
  print -u2 -r -- "App version drift: expected $EXPECTED_IDENTITY, found $APP_VERSION ($APP_BUILD)."
  exit 1
fi
if [[ "$CLI_IDENTITY" != "$EXPECTED_IDENTITY" ]]; then
  print -u2 -r -- "CLI version drift: expected $EXPECTED_IDENTITY, found $CLI_IDENTITY."
  exit 1
fi
if [[ "$AGENT_IDENTITY" != "$EXPECTED_IDENTITY" ]]; then
  print -u2 -r -- "Agent version drift: expected $EXPECTED_IDENTITY, found $AGENT_IDENTITY."
  exit 1
fi
