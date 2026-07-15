#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Cleanroom.app"
ARCHIVE="$ROOT/dist/Cleanroom.zip"
CHECKSUM="$ARCHIVE.sha256"

if [[ ! -d "$APP" ]]; then
  print -u2 -r -- "Missing $APP; run scripts/build-app.sh first."
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
rm -f "$ARCHIVE" "$CHECKSUM"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/usr/bin/shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
/usr/bin/unzip -tq "$ARCHIVE"

print -r -- "$ARCHIVE"
print -r -- "$CHECKSUM"
