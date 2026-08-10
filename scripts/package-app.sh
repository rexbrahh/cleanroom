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
if [[ -n "${CLEANROOM_NOTARY_PROFILE:-}" ]]; then
  "$ROOT/scripts/notarize-app.sh"
elif [[ "${CLEANROOM_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
  print -u2 -r -- "Notarization is required but CLEANROOM_NOTARY_PROFILE is missing."
  exit 77
else
  print -r -- "Notarization skipped: no credentialed profile supplied."
fi
rm -f "$ARCHIVE" "$CHECKSUM"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/usr/bin/shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
/usr/bin/unzip -tq "$ARCHIVE"
"$ROOT/scripts/generate-update-manifest.sh"
"$ROOT/scripts/verify-update.sh" "$ROOT/dist/${CLEANROOM_UPDATE_CHANNEL:-stable}.json" "$ARCHIVE"

print -r -- "$ARCHIVE"
print -r -- "$CHECKSUM"
