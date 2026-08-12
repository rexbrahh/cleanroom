#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CHANNEL="${CLEANROOM_UPDATE_CHANNEL:-stable}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/dist/Cleanroom.app/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/dist/Cleanroom.app/Contents/Info.plist")"
ARCHIVE="$ROOT/dist/Cleanroom.zip"
MANIFEST="$ROOT/dist/$CHANNEL.json"
BASE_URL="${CLEANROOM_UPDATE_BASE_URL:-https://github.com/rexbrahh/cleanroom/releases/download/v$VERSION}"

[[ "$CHANNEL" == stable || "$CHANNEL" == beta ]] || {
  print -u2 -r -- "CLEANROOM_UPDATE_CHANNEL must be stable or beta."
  exit 1
}
[[ "$BASE_URL" == https://* ]] || {
  print -u2 -r -- "CLEANROOM_UPDATE_BASE_URL must use HTTPS."
  exit 1
}
[[ -f "$ARCHIVE" ]] || {
  print -u2 -r -- "Missing $ARCHIVE; package the app first."
  exit 1
}

SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
PUBLISHED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
print -r -- "{\"schemaVersion\":1,\"channel\":\"$CHANNEL\",\"version\":\"$VERSION\",\"build\":\"$BUILD\",\"archiveURL\":\"$BASE_URL/Cleanroom.zip\",\"sha256\":\"$SHA256\",\"minimumSystemVersion\":\"15.0\",\"publishedAt\":\"$PUBLISHED_AT\"}" > "$MANIFEST"
/usr/bin/plutil -extract schemaVersion raw -o - "$MANIFEST" >/dev/null
/usr/bin/plutil -extract sha256 raw -o - "$MANIFEST" >/dev/null
print -r -- "$MANIFEST"
